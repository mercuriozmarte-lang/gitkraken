library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_rx is
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
end uart_rx;

architecture rtl of uart_rx is

    constant BIT_TIME : integer := CLK_HZ / BAUD;
    constant HALF_BIT : integer := BIT_TIME / 2;

    type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
    signal state : state_t := S_IDLE;

    signal baud_cnt : integer range 0 to BIT_TIME-1 := 0;
    signal bit_idx  : integer range 0 to 7 := 0;
    signal shreg    : std_logic_vector(7 downto 0) := (others => '0');

begin

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state      <= S_IDLE;
            baud_cnt   <= 0;
            bit_idx    <= 0;
            shreg      <= (others => '0');
            data_out   <= (others => '0');
            data_valid <= '0';
        elsif rising_edge(clk) then
            data_valid <= '0';

            case state is
                when S_IDLE =>
                    if rx = '0' then
                        baud_cnt <= 0;
                        state    <= S_START;
                    end if;

                when S_START =>
                    if baud_cnt = HALF_BIT then
                        if rx = '0' then
                            baud_cnt <= 0;
                            bit_idx  <= 0;
                            state    <= S_DATA;
                        else
                            state <= S_IDLE;
                        end if;
                    else
                        baud_cnt <= baud_cnt + 1;
                    end if;

                when S_DATA =>
                    if baud_cnt = BIT_TIME-1 then
                        baud_cnt <= 0;
                        shreg    <= rx & shreg(7 downto 1);
                        if bit_idx = 7 then
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                        end if;
                    else
                        baud_cnt <= baud_cnt + 1;
                    end if;

                when S_STOP =>
                    if baud_cnt = BIT_TIME-1 then
                        baud_cnt   <= 0;
                        data_out   <= shreg;
                        data_valid <= '1';
                        state      <= S_IDLE;
                    else
                        baud_cnt <= baud_cnt + 1;
                    end if;
            end case;
        end if;
    end process;

end rtl;