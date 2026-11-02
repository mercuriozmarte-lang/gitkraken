library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity keyboard_uart is
    generic (
        CLK_HZ : integer := 50_000_000;
        BAUD   : integer := 115200
    );
    port (
        clk            : in  std_logic;
        reset_n        : in  std_logic;
        rx_in          : in  std_logic;
        scancode       : out std_logic_vector(7 downto 0);
        scancode_valid : out std_logic;
        -- Salida en bruto del receptor: se reutiliza para SERDATR (consola serie)
        rx_byte_out    : out std_logic_vector(7 downto 0);
        rx_valid_out   : out std_logic
    );
end keyboard_uart;

architecture rtl of keyboard_uart is

    component uart_rx is
        generic (
            CLK_HZ : integer := 50_000_000;
            BAUD   : integer := 115200
        );
        port (
            clk       : in  std_logic;
            rst_n     : in  std_logic;
            rx        : in  std_logic;
            data_out  : out std_logic_vector(7 downto 0);
            data_valid: out std_logic
        );
    end component;

    signal rx_data  : std_logic_vector(7 downto 0);
    signal rx_valid : std_logic;

    -- FSM: A [ : ] HH LL   (el ':' es opcional y se ignora)
    type state_t is (S_IDLE, S_WAIT_HI, S_WAIT_LO, S_EMIT);
    signal state : state_t := S_IDLE;

    signal hi_nibble : std_logic_vector(3 downto 0) := (others => '0');
    signal lo_nibble : std_logic_vector(3 downto 0) := (others => '0');

    signal scancode_int : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_int    : std_logic := '0';

    function hex_to_nibble(c : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable v : integer;
    begin
        v := to_integer(unsigned(c));
        if v >= 48 and v <= 57 then          -- '0'..'9'
            return std_logic_vector(to_unsigned(v - 48, 4));
        elsif v >= 65 and v <= 70 then       -- 'A'..'F'
            return std_logic_vector(to_unsigned(v - 55, 4));
        elsif v >= 97 and v <= 102 then      -- 'a'..'f'
            return std_logic_vector(to_unsigned(v - 87, 4));
        else
            return "0000";
        end if;
    end function;

    function is_hex(c : std_logic_vector(7 downto 0)) return boolean is
        variable v : integer;
    begin
        v := to_integer(unsigned(c));
        return (v >= 48 and v <= 57) or
               (v >= 65 and v <= 70) or
               (v >= 97 and v <= 102);
    end function;

begin

    inst_uart_rx : uart_rx
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
        port map (
            clk        => clk,
            rst_n      => reset_n,
            rx         => rx_in,
            data_out   => rx_data,
            data_valid => rx_valid
        );

    process(clk, reset_n)
    begin
        if reset_n = '0' then
            state        <= S_IDLE;
            hi_nibble    <= (others => '0');
            lo_nibble    <= (others => '0');
            scancode_int <= (others => '0');
            valid_int    <= '0';
        elsif rising_edge(clk) then
            valid_int <= '0';

            case state is
                when S_IDLE =>
                    if rx_valid = '1' and rx_data = x"41" then   -- 'A'
                        state <= S_WAIT_HI;
                    end if;

                when S_WAIT_HI =>
                    if rx_valid = '1' then
                        if is_hex(rx_data) then
                            hi_nibble <= hex_to_nibble(rx_data);
                            state     <= S_WAIT_LO;
                        elsif rx_data = x"3A" then               -- ':' opcional
                            null;
                        else
                            state <= S_IDLE;
                        end if;
                    end if;

                when S_WAIT_LO =>
                    if rx_valid = '1' then
                        if is_hex(rx_data) then
                            lo_nibble <= hex_to_nibble(rx_data);
                            state     <= S_EMIT;
                        elsif rx_data = x"3A" then               -- ':' opcional
                            null;
                        else
                            state <= S_IDLE;
                        end if;
                    end if;

                when S_EMIT =>
                    scancode_int <= hi_nibble & lo_nibble;
                    valid_int    <= '1';
                    state        <= S_IDLE;

                when others =>
                    state <= S_IDLE;
            end case;
        end if;
    end process;

    scancode       <= scancode_int;
    scancode_valid <= valid_int;

    -- Byte recibido tal cual, para la consola serie (SERDATR)
    rx_byte_out  <= rx_data;
    rx_valid_out <= rx_valid;

end rtl;