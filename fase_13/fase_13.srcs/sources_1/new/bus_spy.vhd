library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bus_spy is
    generic (
        CLK_HZ      : integer := 50_000_000;
        BAUD        : integer := 115200;
        -- FILTER_MODE:
        --   0 = sin filtro (envía todo, saturará la UART)
        --   1 = escrituras + lecturas a chipset/CIA  (Opción B)
        --   2 = ROM + RAM + chipset + CIA            (Opción A)
        FILTER_MODE : integer := 1
    );
    port (
        clk         : in  std_logic;
        reset_n     : in  std_logic;
        -- Bus a observar
        cpu_as_n    : in  std_logic;
        cpu_rw      : in  std_logic;
        cpu_addr    : in  std_logic_vector(23 downto 0);
        cpu_data    : in  std_logic_vector(15 downto 0);
        -- UART
        uart_tx_out : out std_logic
    );
end bus_spy;

architecture rtl of bus_spy is

    component uart_tx is
        generic (
            CLK_HZ : integer := 50_000_000;
            BAUD   : integer := 115200
        );
        port (
            clk     : in  std_logic;
            rst_n   : in  std_logic;
            data_in : in  std_logic_vector(7 downto 0);
            valid   : in  std_logic;
            ready   : out std_logic;
            tx      : out std_logic
        );
    end component;

    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid : std_logic := '0';
    signal tx_ready : std_logic;

    type msg_t is array (0 to 31) of std_logic_vector(7 downto 0);
    signal msg      : msg_t := (others => (others => '0'));
    signal msg_len  : integer range 1 to 32 := 1;
    signal msg_idx  : integer range 0 to 31 := 0;

    type state_t is (S_IDLE, S_CAPTURE, S_SEND, S_WAIT_LOW, S_WAIT_READY, S_WAIT_DONE);
    signal state : state_t := S_IDLE;

    signal prev_as_n : std_logic := '1';
    signal busy      : std_logic := '0';
    
    
    
        -- Función: nibble a ASCII hexadecimal
    function nib_to_hex(n : std_logic_vector(3 downto 0)) return std_logic_vector is
        variable v : integer;
    begin
        v := to_integer(unsigned(n));
        if v < 10 then
            return std_logic_vector(to_unsigned(v + 48, 8));  -- '0'..'9'
        else
            return std_logic_vector(to_unsigned(v + 55, 8));  -- 'A'..'F'
        end if;
    end function;
    

    -- Función de filtro: devuelve TRUE si el acceso debe mostrarse
    function pass_filter(
        addr : std_logic_vector(23 downto 0);
        rw   : std_logic;
        mode : integer
    ) return boolean is
        variable is_rom     : boolean;
        variable is_chipset : boolean;
        variable is_cia_a   : boolean;
        variable is_cia_b   : boolean;
        variable is_ram     : boolean;
    begin
        -- Identificación de rangos
        is_rom     := (addr(23 downto 19) = "11111");          -- $F80000-$FFFFFF
        is_chipset := (addr(23 downto 16) = x"DF");            -- $DFxxxx
        is_cia_a   := (addr(23 downto 12) = x"BFE");           -- $BFExxx
        is_cia_b   := (addr(23 downto 12) = x"BFD");           -- $BFDxxx
        is_ram     := (addr(23 downto 19) = "00000") or        -- $000000-$07FFFF
                      (addr(23 downto 19) = "11000");          -- $C00000-$C7FFFF

        case mode is
            when 0 =>
                -- Sin filtro
                return true;

            when 1 =>
                -- Escrituras (a cualquier dirección) + lecturas a chipset/CIA
                if rw = '0' then
                    return true;                     -- cualquier escritura
                else
                    return is_chipset or is_cia_a or is_cia_b;
                end if;

            when 2 =>
                -- ROM + RAM + chipset + CIA
                return is_rom or is_ram or is_chipset or is_cia_a or is_cia_b;

            when others =>
                return false;
        end case;
    end function;

begin

    inst_uart : uart_tx
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
        port map (
            clk     => clk,
            rst_n   => reset_n,
            data_in => tx_data,
            valid   => tx_valid,
            ready   => tx_ready,
            tx      => uart_tx_out
        );

    process(clk, reset_n)
    begin
        if reset_n = '0' then
            prev_as_n <= '1';
            state     <= S_IDLE;
            tx_valid  <= '0';
            msg_idx   <= 0;
            busy      <= '0';
        elsif rising_edge(clk) then
            case state is

                when S_IDLE =>
                    tx_valid <= '0';
                    if cpu_as_n = '0' and prev_as_n = '1' and busy = '0' then
                        if pass_filter(cpu_addr, cpu_rw, FILTER_MODE) then
                            state <= S_CAPTURE;
                        end if;
                    end if;

                       when S_CAPTURE =>
                    if cpu_rw = '1' then
                        msg(0) <= x"52";  -- 'R'
                    else
                        msg(0) <= x"57";  -- 'W'
                    end if;
                    msg(1)  <= x"20";     -- ' '
                    -- Dirección 24 bits en 6 dígitos hex
                    msg(2)  <= nib_to_hex(cpu_addr(23 downto 20));
                    msg(3)  <= nib_to_hex(cpu_addr(19 downto 16));
                    msg(4)  <= nib_to_hex(cpu_addr(15 downto 12));
                    msg(5)  <= nib_to_hex(cpu_addr(11 downto  8));
                    msg(6)  <= nib_to_hex(cpu_addr( 7 downto  4));
                    msg(7)  <= nib_to_hex(cpu_addr( 3 downto  0));
                    msg(8)  <= x"20";     -- ' '
                    -- Dato 16 bits en 4 dígitos hex
                    msg(9)  <= nib_to_hex(cpu_data(15 downto 12));
                    msg(10) <= nib_to_hex(cpu_data(11 downto  8));
                    msg(11) <= nib_to_hex(cpu_data( 7 downto  4));
                    msg(12) <= nib_to_hex(cpu_data( 3 downto  0));
                    msg(13) <= x"0D";     -- CR
                    msg(14) <= x"0A";     -- LF
                    msg_len <= 15;
                    msg_idx <= 0;
                    state   <= S_SEND;

                when S_SEND =>
                    if tx_ready = '1' then
                        tx_data  <= msg(msg_idx);
                        tx_valid <= '1';
                        state    <= S_WAIT_LOW;
                    end if;

                when S_WAIT_LOW =>
                    tx_valid <= '0';
                    if tx_ready = '0' then
                        state <= S_WAIT_READY;
                    end if;

                when S_WAIT_READY =>
                    if tx_ready = '1' then
                        if msg_idx = msg_len - 1 then
                            state <= S_WAIT_DONE;
                        else
                            msg_idx <= msg_idx + 1;
                            state   <= S_SEND;
                        end if;
                    end if;

                when S_WAIT_DONE =>
                    if cpu_as_n = '1' then
                        busy  <= '0';
                        state <= S_IDLE;
                    else
                        busy <= '1';
                    end if;

            end case;

            prev_as_n <= cpu_as_n;
        end if;
    end process;

end rtl;