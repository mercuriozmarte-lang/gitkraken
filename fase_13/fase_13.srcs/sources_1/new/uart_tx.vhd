-------------------------------------------------------------------
-- uart_tx.vhd
-- Transmisor UART genérico, 8N1, sin paridad.
-- Uso: poner valid='1' durante un ciclo cuando ready='1'.
--      El módulo pone ready='0' mientras transmite y vuelve a '1'
--      cuando termina.
-------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_tx is
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
end uart_tx;

architecture rtl of uart_tx is

    constant BIT_TIME : integer := CLK_HZ / BAUD;

    type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
    signal state : state_t := S_IDLE;

    signal baud_cnt : integer range 0 to BIT_TIME-1 := 0;
    signal bit_idx  : integer range 0 to 7 := 0;
    signal shreg    : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_r     : std_logic := '1';

begin

    tx    <= tx_r;
    ready <= '1' when state = S_IDLE else '0';

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state    <= S_IDLE;
            tx_r     <= '1';
            baud_cnt <= 0;
            bit_idx  <= 0;
            shreg    <= (others => '0');
        elsif rising_edge(clk) then
            case state is
                when S_IDLE =>
                    tx_r <= '1';
                    if valid = '1' then
                        shreg    <= data_in;
                        state    <= S_START;
                        baud_cnt <= 0;
                    end if;

                when S_START =>
                    tx_r <= '0';
                    if baud_cnt = BIT_TIME-1 then
                        baud_cnt <= 0;
                        state    <= S_DATA;
                        bit_idx  <= 0;
                    else
                        baud_cnt <= baud_cnt + 1;
                    end if;

                when S_DATA =>
                    tx_r <= shreg(bit_idx);
                    if baud_cnt = BIT_TIME-1 then
                        baud_cnt <= 0;
                        if bit_idx = 7 then
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 1;
                        end if;
                    else
                        baud_cnt <= baud_cnt + 1;
                    end if;

                when S_STOP =>
                    tx_r <= '1';
                    if baud_cnt = BIT_TIME-1 then
                        baud_cnt <= 0;
                        state    <= S_IDLE;
                    else
                        baud_cnt <= baud_cnt + 1;
                    end if;
            end case;
        end if;
    end process;

end rtl;