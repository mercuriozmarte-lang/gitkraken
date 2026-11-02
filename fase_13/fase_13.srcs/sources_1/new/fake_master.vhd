library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fake_master is
    Port (
        clk          : in  std_logic;
        reset_n      : in  std_logic;
        cpu_addr     : out std_logic_vector(23 downto 1);
        cpu_wdata    : out std_logic_vector(15 downto 0);
        cpu_rdata    : in  std_logic_vector(15 downto 0);
        cpu_as_n     : out std_logic;
        cpu_uds_n    : out std_logic;
        cpu_lds_n    : out std_logic;
        cpu_rw       : out std_logic;
        cpu_dtack_n  : in  std_logic;
        uart_tx      : out std_logic
    );
end fake_master;

architecture rtl of fake_master is

    type pattern_array is array(0 to 3) of std_logic_vector(15 downto 0);
    constant PATTERNS : pattern_array := (x"5555", x"AAAA", x"0000", x"FFFF");
    constant TEST_ADDR : std_logic_vector(23 downto 1) := (others => '0');

    constant T_WRITE : integer := 20;
    constant T_GAP   : integer := 5;
    constant T_READ  : integer := 20;

    type state_t is (S_BANNER, S_INIT, S_WRITE, S_WRITE_END, S_READ,
                     S_READ_CAP, S_UART, S_DONE);
    signal state : state_t := S_BANNER;

    signal tick      : integer range 0 to 255 := 0;
    signal test_idx  : integer range 0 to 3 := 0;
    signal read_val  : std_logic_vector(15 downto 0) := (others => '0');
    signal write_val : std_logic_vector(15 downto 0) := (others => '0');

    signal addr_r : std_logic_vector(23 downto 1) := TEST_ADDR;
    signal rw_r   : std_logic := '1';
    signal as_r   : std_logic := '1';
    signal uds_r  : std_logic := '1';
    signal lds_r  : std_logic := '1';
    signal data_r : std_logic_vector(15 downto 0) := (others => '0');

    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid : std_logic := '0';
    signal tx_ready : std_logic;
    signal msg_idx  : integer range 0 to 31 := 0;
    signal u_state  : integer range 0 to 3 := 0;
    signal banner   : std_logic := '1';

    function nib_to_hex(n : std_logic_vector(3 downto 0))
                       return std_logic_vector is
        variable v : integer;
    begin
        v := to_integer(unsigned(n));
        if v < 10 then
            return std_logic_vector(to_unsigned(v + 48, 8));
        else
            return std_logic_vector(to_unsigned(v + 55, 8));
        end if;
    end function;

begin

    cpu_addr  <= addr_r;
    cpu_rw    <= rw_r;
    cpu_as_n  <= as_r;
    cpu_uds_n <= uds_r;
    cpu_lds_n <= lds_r;
    cpu_wdata <= data_r;   -- siempre conducido, sin tri-state

    inst_uart_tx : entity work.uart_tx
        generic map (CLK_HZ => 50_000_000, BAUD => 115200)
        port map (
            clk     => clk,
            rst_n   => reset_n,
            data_in => tx_data,
            valid   => tx_valid,
            ready   => tx_ready,
            tx      => uart_tx
        );

    process(msg_idx, write_val, read_val, banner)
    begin
        if banner = '1' then
            case msg_idx is
                when 0 => tx_data <= x"48";
                when 1 => tx_data <= x"4F";
                when 2 => tx_data <= x"4C";
                when 3 => tx_data <= x"41";
                when 4 => tx_data <= x"0D";
                when 5 => tx_data <= x"0A";
                when others => tx_data <= x"00";
            end case;
        else
            case msg_idx is
                when 0  => tx_data <= x"57";
                when 1  => tx_data <= x"3A";
                when 2  => tx_data <= nib_to_hex(write_val(15 downto 12));
                when 3  => tx_data <= nib_to_hex(write_val(11 downto 8));
                when 4  => tx_data <= nib_to_hex(write_val(7 downto 4));
                when 5  => tx_data <= nib_to_hex(write_val(3 downto 0));
                when 6  => tx_data <= x"20";
                when 7  => tx_data <= x"52";
                when 8  => tx_data <= x"3A";
                when 9  => tx_data <= nib_to_hex(read_val(15 downto 12));
                when 10 => tx_data <= nib_to_hex(read_val(11 downto 8));
                when 11 => tx_data <= nib_to_hex(read_val(7 downto 4));
                when 12 => tx_data <= nib_to_hex(read_val(3 downto 0));
                when 13 => tx_data <= x"0D";
                when 14 => tx_data <= x"0A";
                when others => tx_data <= x"00";
            end case;
        end if;
    end process;

    process(clk, reset_n)
    begin
        if reset_n = '0' then
            state    <= S_BANNER;
            tick     <= 0;
            test_idx <= 0;
            as_r     <= '1';
            rw_r     <= '1';
            uds_r    <= '1';
            lds_r    <= '1';
            tx_valid <= '0';
            msg_idx  <= 0;
            u_state  <= 0;
            banner   <= '1';
        elsif rising_edge(clk) then
            case state is
                when S_BANNER =>
                    case u_state is
                        when 0 =>
                            if tx_ready = '1' then
                                tx_valid <= '1'; u_state <= 1;
                            end if;
                        when 1 =>
                            tx_valid <= '0';
                            if tx_ready = '0' then u_state <= 2; end if;
                        when 2 =>
                            if tx_ready = '1' then
                                if msg_idx = 5 then
                                    banner  <= '0';
                                    msg_idx <= 0;
                                    u_state <= 0;
                                    state   <= S_INIT;
                                else
                                    msg_idx <= msg_idx + 1;
                                    u_state <= 0;
                                end if;
                            end if;
                        when others => u_state <= 0;
                    end case;

                when S_INIT =>
                    write_val <= PATTERNS(test_idx);
                    data_r    <= PATTERNS(test_idx);
                    addr_r    <= TEST_ADDR;
                    rw_r      <= '0';
                    uds_r     <= '0';
                    lds_r     <= '0';
                    as_r      <= '0';
                    tick      <= 0;
                    state     <= S_WRITE;

                when S_WRITE =>
                    if tick = T_WRITE - 1 then
                        tick  <= 0;
                        as_r  <= '1';
                        state <= S_WRITE_END;
                    else
                        tick <= tick + 1;
                    end if;

                when S_WRITE_END =>
                    if tick = T_GAP - 1 then
                        tick  <= 0;
                        rw_r  <= '1';
                        uds_r <= '0';
                        lds_r <= '0';
                        as_r  <= '0';
                        state <= S_READ;
                    else
                        tick <= tick + 1;
                    end if;

                when S_READ =>
                    if tick = T_READ - 1 then
                        tick     <= 0;
                        read_val <= cpu_rdata;
                        as_r     <= '1';
                        state    <= S_READ_CAP;
                    else
                        tick <= tick + 1;
                    end if;

                when S_READ_CAP =>
                    if tick = T_GAP - 1 then
                        tick    <= 0;
                        msg_idx <= 0;
                        u_state <= 0;
                        state   <= S_UART;
                    else
                        tick <= tick + 1;
                    end if;

                when S_UART =>
                    case u_state is
                        when 0 =>
                            if tx_ready = '1' then
                                tx_valid <= '1'; u_state <= 1;
                            end if;
                        when 1 =>
                            tx_valid <= '0';
                            if tx_ready = '0' then u_state <= 2; end if;
                        when 2 =>
                            if tx_ready = '1' then
                                if msg_idx = 14 then
                                    if test_idx = 3 then
                                        state <= S_DONE;
                                    else
                                        test_idx <= test_idx + 1;
                                        state    <= S_INIT;
                                    end if;
                                else
                                    msg_idx <= msg_idx + 1;
                                    u_state <= 0;
                                end if;
                            end if;
                        when others => u_state <= 0;
                    end case;

                when S_DONE =>
                    null;

                when others =>
                    state <= S_BANNER;
            end case;
        end if;
    end process;

end rtl;