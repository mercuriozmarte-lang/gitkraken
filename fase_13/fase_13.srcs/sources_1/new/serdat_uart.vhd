---------------------------------------------------
-- FICHERO: serdat_uart.vhd
-- PUENTE SERDAT -> UART  (para DiagROM y futuros KS que usen serie)
--
-- DiagROM escribe cada caracter en SERDAT ($DFF030). Este modulo:
--   1. Recibe el byte (wr_byte) con un pulso (wr_en)
--   2. Lo mete en una FIFO
--   3. Lo transmite por uart_tx a la velocidad configurada (BAUD)
--   4. Expone 'tbe' (transmit buffer empty = hay sitio en la FIFO)
--      para que el top lo devuelva en SERDATR bit 13; asi DiagROM
--      espera si la FIFO se llena y NO se pierde ningun caracter.
--
-- Ignora SERPER (el baud que DiagROM cree usar): transmitimos a la
-- velocidad fija BAUD, que es la que lee tu consola/PuTTY.
--
-- Reutiliza la entidad work.uart_tx ya existente en el proyecto.
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity serdat_uart is
    generic (
        CLK_HZ    : integer := 28_375_000;
        BAUD      : integer := 115200;
        ADDR_BITS : integer := 11           -- FIFO = 2^11 = 2048 bytes
    );
    port (
        clk     : in  std_logic;
        reset_n : in  std_logic;
        wr_en   : in  std_logic;                       -- pulso de 1 ciclo
        wr_byte : in  std_logic_vector(7 downto 0);    -- byte ASCII de SERDAT
        tbe     : out std_logic;                       -- 1 = FIFO no llena
        uart_tx : out std_logic
    );
end serdat_uart;

architecture rtl of serdat_uart is

    constant DEPTH : integer := 2**ADDR_BITS;

    type ram_t is array (0 to DEPTH-1) of std_logic_vector(7 downto 0);
    signal fifo   : ram_t := (others => (others => '0'));
    signal wr_ptr : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
    signal rd_ptr : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
    signal count  : unsigned(ADDR_BITS downto 0)   := (others => '0');

    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid : std_logic := '0';
    signal tx_ready : std_logic;

    type st_t is (S_IDLE, S_BUSY);
    signal st : st_t := S_IDLE;

begin

    -- TBE: hay sitio mientras la FIFO no este llena
    tbe <= '0' when count = to_unsigned(DEPTH, count'length) else '1';

    -- Transmisor UART reutilizado del proyecto
    inst_tx : entity work.uart_tx
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
        port map (clk     => clk,
                  rst_n   => reset_n,
                  data_in => tx_data,
                  valid   => tx_valid,
                  ready   => tx_ready,
                  tx      => uart_tx);

    process(clk, reset_n)
        variable do_push : boolean;
        variable do_pop  : boolean;
    begin
        if reset_n = '0' then
            wr_ptr   <= (others => '0');
            rd_ptr   <= (others => '0');
            count    <= (others => '0');
            tx_valid <= '0';
            st       <= S_IDLE;
        elsif rising_edge(clk) then
            do_push := false;
            do_pop  := false;
            tx_valid <= '0';

            -- ── PUSH: meter byte de SERDAT en la FIFO ──
            if wr_en = '1' and count < to_unsigned(DEPTH, count'length) then
                fifo(to_integer(wr_ptr)) <= wr_byte;
                wr_ptr  <= wr_ptr + 1;
                do_push := true;
            end if;

            -- ── POP: sacar byte de la FIFO al uart_tx ──
            case st is
                when S_IDLE =>
                    if count > 0 and tx_ready = '1' then
                        tx_data  <= fifo(to_integer(rd_ptr));
                        tx_valid <= '1';
                        rd_ptr   <= rd_ptr + 1;
                        do_pop   := true;
                        st       <= S_BUSY;
                    end if;
                when S_BUSY =>
                    -- esperar a que el uart_tx acepte (ready baja) antes
                    -- de permitir el siguiente pop
                    if tx_ready = '0' then
                        st <= S_IDLE;
                    end if;
            end case;

            -- ── Actualizacion del contador ──
            if do_push and not do_pop then
                count <= count + 1;
            elsif do_pop and not do_push then
                count <= count - 1;
            end if;
        end if;
    end process;

end rtl;
