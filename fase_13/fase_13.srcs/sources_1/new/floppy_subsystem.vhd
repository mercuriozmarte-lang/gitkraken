--------------------------------------------------------------------------------
-- floppy_subsystem.vhd
--
-- Subsistema de disquetera DF0 para fase_13:
--   * Controlador de la SRAM externa (1 MB, 512K x 16) donde vive el ADF.
--   * Cargador del ADF por UART a 1 Mbaud (cabecera "ADF1" + longitud BE32).
--   * Puente SD -> SRAM para el modulo paula_floppy de Minimig.
--   * Instancia de paula_floppy (Verilog) en modo lectura, DF0.
--   * DMA de disco simple: lee DSKDATR y escribe en chip RAM en DSKPT.
--   * Registros DSKPT y ADKCON; estados de unidad para CIA-A.
--
-- El modulo paula_floppy se instancia POSICIONALMENTE porque sus puertos
-- Verilog empiezan por '_' (no son identificadores VHDL validos).
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity floppy_subsystem is
    port (
        clk         : in  std_logic;
        reset_n     : in  std_logic;   -- PLL lock (activo bajo)
        system_ready: in  std_logic;   -- Amiga fuera de reset
        clk7_en     : in  std_logic;
        clk7n_en    : in  std_logic;
        sof         : in  std_logic;   -- pulso de VBLANK (60 Hz)

        uart_rx     : in  std_logic;
        uart_tx     : out std_logic;

        -- SRAM externa (512K x 16)
        sram_addr   : out std_logic_vector(18 downto 0);
        sram_data_a : inout std_logic_vector(7 downto 0);
        sram_data_b : inout std_logic_vector(7 downto 0);
        sram_we_a   : out std_logic;
        sram_oe_a   : out std_logic;
        sram_ce_a   : out std_logic;
        sram_we_b   : out std_logic;
        sram_oe_b   : out std_logic;
        sram_ce_b   : out std_logic;

        -- CIA-B (control) y CIA-A (estado)
        ciab_prb    : in  std_logic_vector(7 downto 0);
        dsk_status  : out std_logic_vector(3 downto 0); -- RDY,TRK0,WPRO,CHNG

        -- Bus de registros del chipset
        reg_addr    : in  std_logic_vector(8 downto 1);
        reg_data_in : in  std_logic_vector(15 downto 0);
        reg_we      : in  std_logic;
        reg_data_out: out std_logic_vector(15 downto 0);

        dmacon_dsken: in  std_logic;

        -- DMA de disco -> chip RAM
        dma_req     : out std_logic;
        dma_gnt     : in  std_logic;
        dma_addr    : out std_logic_vector(18 downto 1);
        dma_data    : out std_logic_vector(15 downto 0);
        dma_we      : out std_logic;

        -- Interrupciones y estado del cargador
        blckint     : out std_logic;
        syncint     : out std_logic;
        adf_done    : out std_logic;
        adf_timeout : out std_logic
    );
end floppy_subsystem;

architecture rtl of floppy_subsystem is

    ------------------------------------------------------------------
    -- SRAM controller
    ------------------------------------------------------------------
    type sram_state_t is (S_IDLE, S_SETUP, S_ACCESS);
    signal sram_state : sram_state_t := S_IDLE;

    signal sram_req   : std_logic := '0';
    signal sram_we_i  : std_logic := '0';
    signal sram_addr_i: std_logic_vector(18 downto 0) := (others => '0');
    signal sram_wdata : std_logic_vector(15 downto 0) := (others => '0');
    signal sram_rdata : std_logic_vector(15 downto 0) := (others => '0');
    signal sram_ack   : std_logic := '0';
    signal sram_drive : std_logic := '0';

    ------------------------------------------------------------------
    -- Cargador del ADF (UART 1 Mbaud)
    ------------------------------------------------------------------
    constant ADF_MAX  : integer := 1024 * 1024;

    type ld_state_t is (L_MAGIC, L_LEN, L_DATA, L_ACK, L_DONE, L_TIMEOUT);
    signal ld_state   : ld_state_t := L_MAGIC;
    signal ld_magic   : std_logic_vector(31 downto 0) := (others => '0');
    signal ld_magic_n : integer range 0 to 3 := 0;
    signal ld_len     : unsigned(31 downto 0) := (others => '0');
    signal ld_len_next: std_logic_vector(31 downto 0) := (others => '0');
    signal ld_len_n   : integer range 0 to 3 := 0;
    signal ld_count   : unsigned(31 downto 0) := (others => '0');
    signal ld_byte_n  : std_logic := '0';   -- 0 = primero del par
    signal ld_wdata   : std_logic_vector(15 downto 0) := (others => '0');
    signal ld_addr    : std_logic_vector(18 downto 0) := (others => '0');
    signal ld_req     : std_logic := '0';
    signal ld_wait    : std_logic := '0';
    signal ld_done    : std_logic := '0';
    signal ld_timeout : std_logic := '0';
    signal ld_timer   : unsigned(30 downto 0) := (others => '0');
    signal ld_len_r   : unsigned(31 downto 0) := (others => '0');

    signal ld_rx_data  : std_logic_vector(7 downto 0);
    signal ld_rx_valid : std_logic;

    signal ld_tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal ld_tx_valid : std_logic := '0';
    signal ld_tx_ready : std_logic;
    signal ld_ack_sent : std_logic := '0';
    signal bc_timer    : unsigned(23 downto 0) := (others => '0');
    signal ld_tx       : std_logic;

    ------------------------------------------------------------------
    -- Puente SD -> SRAM para paula_floppy
    ------------------------------------------------------------------
    type br_state_t is (B_IDLE, B_READ, B_STREAM, B_DONE);
    signal br_state   : br_state_t := B_IDLE;
    signal br_sector  : unsigned(31 downto 0) := (others => '0');
    signal br_word    : unsigned(8 downto 0) := (others => '0');
    signal br_req     : std_logic := '0';
    signal br_addr    : std_logic_vector(18 downto 0) := (others => '0');
    signal br_busy    : std_logic := '0';
    signal br_done    : std_logic := '0';
    signal br_cnt     : unsigned(8 downto 0) := (others => '0');
    signal br_strobe  : std_logic := '0';
    signal br_byte    : std_logic_vector(7 downto 0) := (others => '0');
    type br_buf_t is array (0 to 511) of std_logic_vector(7 downto 0);
    signal br_buf     : br_buf_t := (others => (others => '0'));

    ------------------------------------------------------------------
    -- paula_floppy (Minimig)
    ------------------------------------------------------------------
    signal flop_reset   : std_logic;
    signal flop_reg_addr: std_logic_vector(8 downto 1) := (others => '0');
    signal flop_data_in : std_logic_vector(15 downto 0) := (others => '0');
    signal flop_data_out: std_logic_vector(15 downto 0);
    signal flop_dmal    : std_logic;
    signal flop_dmas    : std_logic;
    signal flop_track0  : std_logic;
    signal flop_change  : std_logic;
    signal flop_ready   : std_logic;
    signal flop_wprot   : std_logic;
    signal flop_blckint : std_logic;
    signal flop_syncint : std_logic;
    signal flop_sel     : std_logic_vector(3 downto 0);
    signal flop_sdc_rd  : std_logic_vector(3 downto 0);
    signal flop_sdc_sector : std_logic_vector(31 downto 0);
    signal flop_mounted : std_logic_vector(3 downto 0);
    signal flop_override: std_logic := '0';
    signal flop_index   : std_logic;
    signal flop_led     : std_logic;
    signal flop_sdc_wr  : std_logic_vector(3 downto 0);
    signal flop_sdc_bout: std_logic_vector(7 downto 0);

    ------------------------------------------------------------------
    -- DMA de disco
    ------------------------------------------------------------------
    type dma_state_t is (D_IDLE, D_CAP, D_REQ, D_WAIT);
    signal dma_state  : dma_state_t := D_IDLE;
    signal dskpt      : unsigned(23 downto 0) := (others => '0');
    signal dskpt_inc  : std_logic := '0';
    signal dma_req_r  : std_logic := '0';
    signal dma_we_r   : std_logic := '0';
    signal dma_addr_r : std_logic_vector(18 downto 1) := (others => '0');
    signal dma_data_r : std_logic_vector(15 downto 0) := (others => '0');
    signal dma_cap    : std_logic_vector(15 downto 0) := (others => '0');
    signal blck_prev  : std_logic := '0';

    signal adkcon     : std_logic_vector(15 downto 0) := (others => '0');

begin

    ------------------------------------------------------------------
    -- Mux del controlador SRAM: cargador mientras no haya ADF, luego puente
    ------------------------------------------------------------------
    sram_req   <= ld_req when ld_done = '0' else br_req;
    sram_we_i  <= '1'    when ld_done = '0' else '0';
    sram_addr_i<= ld_addr when ld_done = '0' else br_addr;
    sram_wdata <= ld_wdata when ld_done = '0' else x"0000";

    process(clk, reset_n)
    begin
        if reset_n = '0' then
            sram_state <= S_IDLE;
            sram_ack   <= '0';
            sram_drive <= '0';
            sram_ce_a  <= '1';
            sram_ce_b  <= '1';
            sram_oe_a  <= '1';
            sram_oe_b  <= '1';
            sram_we_a  <= '1';
            sram_we_b  <= '1';
            sram_addr  <= (others => '0');
        elsif rising_edge(clk) then
            sram_ack <= '0';
            case sram_state is
                when S_IDLE =>
                    sram_drive <= '0';
                    if sram_req = '1' then
                        sram_addr  <= sram_addr_i;
                        sram_ce_a  <= '0';
                        sram_ce_b  <= '0';
                        if sram_we_i = '1' then
                            sram_we_a <= '0';
                            sram_we_b <= '0';
                            sram_oe_a <= '1';
                            sram_oe_b <= '1';
                            sram_drive <= '1';
                        else
                            sram_we_a <= '1';
                            sram_we_b <= '1';
                            sram_oe_a <= '0';
                            sram_oe_b <= '0';
                        end if;
                        sram_state <= S_SETUP;
                    end if;

                when S_SETUP =>
                    sram_state <= S_ACCESS;

                when S_ACCESS =>
                    if sram_we_i = '0' then
                        sram_rdata <= sram_data_b & sram_data_a;
                    end if;
                    sram_ce_a  <= '1';
                    sram_ce_b  <= '1';
                    sram_oe_a  <= '1';
                    sram_oe_b  <= '1';
                    sram_we_a  <= '1';
                    sram_we_b  <= '1';
                    sram_drive <= '0';
                    sram_ack   <= '1';
                    sram_state <= S_IDLE;
            end case;
        end if;
    end process;

    sram_data_a <= sram_wdata(7 downto 0) when sram_drive = '1' else (others => 'Z');
    sram_data_b <= sram_wdata(15 downto 8) when sram_drive = '1' else (others => 'Z');

    ------------------------------------------------------------------
    -- Cargador del ADF
    ------------------------------------------------------------------
    u_rx : entity work.uart_rx
        generic map (CLK_HZ => 28_375_000, BAUD => 1_000_000)
        port map (
            clk        => clk,
            rst_n      => reset_n,
            rx         => uart_rx,
            data_out   => ld_rx_data,
            data_valid => ld_rx_valid
        );

    u_tx : entity work.uart_tx
        generic map (CLK_HZ => 28_375_000, BAUD => 1_000_000)
        port map (
            clk     => clk,
            rst_n   => reset_n,
            data_in => ld_tx_data,
            valid   => ld_tx_valid,
            ready   => ld_tx_ready,
            tx      => ld_tx
        );

    uart_tx <= ld_tx;

    -- Concatenacion en un contexto std_logic_vector puro: evita la ambiguedad
    -- del operador "&" cuando se usa dentro de unsigned(...).
    ld_len_next <= std_logic_vector(ld_len(23 downto 0)) & ld_rx_data;

    process(clk, reset_n)
    begin
        if reset_n = '0' then
            ld_state   <= L_MAGIC;
            ld_magic   <= (others => '0');
            ld_magic_n <= 0;
            ld_len     <= (others => '0');
            ld_len_n   <= 0;
            ld_count   <= (others => '0');
            ld_byte_n  <= '0';
            ld_wdata   <= (others => '0');
            ld_addr    <= (others => '0');
            ld_req     <= '0';
            ld_wait    <= '0';
            ld_done    <= '0';
            ld_timeout <= '0';
            ld_timer   <= (others => '0');
            ld_len_r   <= (others => '0');
            ld_tx_valid<= '0';
            ld_tx_data <= (others => '0');
            ld_ack_sent<= '0';
            bc_timer   <= (others => '0');
        elsif rising_edge(clk) then
            ld_req <= '0';
            if ld_tx_valid = '1' and ld_tx_ready = '1' then
                ld_tx_valid <= '0';
            end if;

            -- Baliza de estado cada ~0,5 s por el UART del cargador:
            --   'M' esperando cabecera, 'L' esperando longitud,
            --   'D' cargando datos, 'T' timeout, 'K' completado.
            -- Sirve para saber si el cargador vive y si el ADF llega.
            if bc_timer /= to_unsigned(14_000_000, 24) then
                bc_timer <= bc_timer + 1;
            else
                bc_timer <= (others => '0');
                if ld_tx_valid = '0' then
                    case ld_state is
                        when L_MAGIC   => ld_tx_data <= x"4D"; -- 'M'
                        when L_LEN     => ld_tx_data <= x"4C"; -- 'L'
                        when L_DATA    => ld_tx_data <= x"44"; -- 'D'
                        when L_ACK     => ld_tx_data <= x"4B"; -- 'K'
                        when L_DONE    => ld_tx_data <= x"4B"; -- 'K'
                        when L_TIMEOUT => ld_tx_data <= x"54"; -- 'T'
                    end case;
                    ld_tx_valid <= '1';
                end if;
            end if;

            if ld_state = L_MAGIC or ld_state = L_LEN then
                if ld_timer /= to_unsigned(1_700_000_000, 31) then
                    ld_timer <= ld_timer + 1;
                else
                    ld_state   <= L_TIMEOUT;
                    ld_timeout <= '1';
                end if;
            elsif ld_state = L_DATA then
                -- Si el flujo se corta a mitad de ADF, no quedarse esperando
                -- para siempre (dejaria la Amiga en reset y la pantalla gris).
                if ld_rx_valid = '1' then
                    ld_timer <= (others => '0');
                elsif ld_timer /= to_unsigned(30_000_000, 31) then
                    ld_timer <= ld_timer + 1;
                else
                    ld_state   <= L_TIMEOUT;
                    ld_timeout <= '1';
                end if;
            end if;

            case ld_state is
                when L_MAGIC =>
                    if ld_rx_valid = '1' then
                        ld_magic <= ld_magic(23 downto 0) & ld_rx_data;
                        if ld_magic_n = 3 then
                            if (ld_magic(23 downto 0) & ld_rx_data) = x"41444631" then -- "ADF1"
                                ld_state   <= L_LEN;
                                ld_len_n   <= 0;
                                ld_len     <= (others => '0');
                                ld_timer   <= (others => '0');
                            else
                                ld_magic_n <= 0;
                            end if;
                        else
                            ld_magic_n <= ld_magic_n + 1;
                        end if;
                    end if;

                when L_LEN =>
                    if ld_rx_valid = '1' then
                        ld_len <= unsigned(ld_len_next);
                        if ld_len_n = 3 then
                            if unsigned(ld_len_next) <= to_unsigned(ADF_MAX, 32) then
                                ld_len_r   <= unsigned(ld_len_next);
                                ld_count   <= (others => '0');
                                ld_addr    <= (others => '0');
                                ld_byte_n  <= '0';
                                ld_state   <= L_DATA;
                            else
                                ld_state   <= L_TIMEOUT;
                                ld_timeout <= '1';
                            end if;
                        else
                            ld_len_n <= ld_len_n + 1;
                        end if;
                    end if;

                when L_DATA =>
                    if ld_wait = '1' then
                        if sram_ack = '1' then
                            ld_wait <= '0';
                        end if;
                    elsif ld_rx_valid = '1' then
                        if ld_byte_n = '0' then
                            ld_wdata(7 downto 0) <= ld_rx_data;
                            ld_byte_n <= '1';
                        else
                            ld_wdata(15 downto 8) <= ld_rx_data;
                            ld_byte_n <= '0';
                            ld_req    <= '1';
                            ld_wait   <= '1';
                            ld_addr <= std_logic_vector(unsigned(ld_addr) + 1);
                        end if;
                        if ld_count = ld_len_r - 1 then
                            -- Enviar el ACK ANTES de soltar system_ready,
                            -- para que el mux de UART siga en el cargador.
                            ld_state <= L_ACK;
                        else
                            ld_count <= ld_count + 1;
                        end if;
                    end if;

                when L_ACK =>
                    if ld_ack_sent = '0' then
                        ld_tx_data  <= x"4B"; -- 'K'
                        ld_tx_valid <= '1';
                        ld_ack_sent <= '1';
                    elsif ld_tx_ready = '1' then
                        ld_done  <= '1';
                        ld_state <= L_DONE;
                    end if;

                when L_DONE =>
                    null;

                when L_TIMEOUT =>
                    null;
            end case;
        end if;
    end process;

    adf_done    <= ld_done;
    adf_timeout <= ld_timeout;

    ------------------------------------------------------------------
    -- Puente SD -> SRAM
    ------------------------------------------------------------------
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            br_state <= B_IDLE;
            br_sector<= (others => '0');
            br_word  <= (others => '0');
            br_req   <= '0';
            br_addr  <= (others => '0');
            br_busy  <= '0';
            br_done  <= '0';
            br_cnt   <= (others => '0');
            br_strobe<= '0';
            br_byte  <= (others => '0');
        elsif rising_edge(clk) then
            br_strobe <= '0';
            br_done   <= '0';

            case br_state is
                when B_IDLE =>
                    br_busy <= '0';
                    if ld_done = '1' and flop_sdc_rd(0) = '1' then
                        br_sector <= unsigned(flop_sdc_sector);
                        br_word   <= (others => '0');
                        br_cnt    <= (others => '0');
                        br_busy   <= '1';
                        br_state  <= B_READ;
                    end if;

                when B_READ =>
                    if br_req = '0' then
                        br_addr <= std_logic_vector(
                            (resize(br_sector, 19) sll 8) +
                             resize(br_word, 19));
                        br_req  <= '1';
                    elsif sram_ack = '1' then
                        br_req <= '0';
                        br_buf(to_integer(br_word) * 2)     <= sram_rdata(7 downto 0);
                        br_buf(to_integer(br_word) * 2 + 1) <= sram_rdata(15 downto 8);
                        if br_word = 255 then
                            br_cnt   <= (others => '0');
                            br_state <= B_STREAM;
                        else
                            br_word <= br_word + 1;
                        end if;
                    end if;

                when B_STREAM =>
                    br_byte   <= br_buf(to_integer(br_cnt));
                    br_strobe <= '1';
                    if br_cnt = 511 then
                        br_state <= B_DONE;
                    else
                        br_cnt <= br_cnt + 1;
                    end if;

                when B_DONE =>
                    br_busy <= '0';
                    br_done <= '1';
                    br_state<= B_IDLE;
            end case;
        end if;
    end process;

    ------------------------------------------------------------------
    -- paula_floppy (Minimig). Mapa POSICIONAL: no cambiar el orden.
    ------------------------------------------------------------------
    flop_reset   <= not system_ready;
    flop_sel     <= "111" & ciab_prb(3);
    flop_mounted <= "0001" when ld_done = '1' else "0000";
    flop_reg_addr<= x"04" when flop_override = '1' else reg_addr;
    flop_data_in <= reg_data_in;

    inst_floppy : entity work.paula_floppy
        port map (
            clk, clk7_en, clk7n_en, flop_reset, '1', sof, dmacon_dsken,
            flop_reg_addr, flop_data_in, flop_data_out,
            flop_dmal, flop_dmas,
            ciab_prb(0), ciab_prb(1), flop_sel, ciab_prb(2), ciab_prb(7),
            flop_track0, flop_change, flop_ready, flop_wprot,
            flop_index, flop_blckint, flop_syncint, adkcon(10), flop_led,
            "01", '1', flop_mounted, std_logic_vector(ld_len_r),
            flop_sdc_rd, flop_sdc_wr, flop_sdc_sector, br_busy, br_done,
            br_strobe, std_logic_vector(br_cnt), br_byte, flop_sdc_bout
        );

    dsk_status <= flop_ready & flop_track0 & flop_wprot & flop_change;

    ------------------------------------------------------------------
    -- Registros DSKPT / ADKCON y lectura
    ------------------------------------------------------------------
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            dskpt  <= (others => '0');
            adkcon <= (others => '0');
        elsif rising_edge(clk) then
            -- Un solo proceso escribe dskpt (evita MDRV-1): la escritura de
            -- la CPU tiene prioridad y el DMA incrementa con dskpt_inc.
            if reg_we = '1' then
                case to_integer(unsigned(reg_addr)) is
                    when 16#10# => dskpt(23 downto 16) <= unsigned(reg_data_in(7 downto 0));
                    when 16#11# => dskpt(15 downto 0)  <= unsigned(reg_data_in);
                    when 16#4F# => adkcon <= reg_data_in;
                    when others => null;
                end case;
            elsif dskpt_inc = '1' then
                dskpt <= dskpt + 2;
            end if;
        end if;
    end process;

    reg_data_out <= flop_data_out;

    ------------------------------------------------------------------
    -- DMA de disco: DSKDATR -> chip RAM en DSKPT
    ------------------------------------------------------------------
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            dma_state  <= D_IDLE;
            dma_req_r  <= '0';
            dma_we_r   <= '0';
            dma_addr_r <= (others => '0');
            dma_data_r <= (others => '0');
            dma_cap    <= (others => '0');
            flop_override <= '0';
            blck_prev  <= '0';
            dskpt_inc  <= '0';
        elsif rising_edge(clk) then
            blck_prev <= flop_blckint;
            case dma_state is
                when D_IDLE =>
                    dma_req_r <= '0';
                    dma_we_r  <= '0';
                    dskpt_inc <= '0';
                    flop_override <= '0';
                    if flop_dmal = '1' and dmacon_dsken = '1' and ld_done = '1' then
                        flop_override <= '1';
                        dma_state <= D_CAP;
                    end if;

                when D_CAP =>
                    dma_cap <= flop_data_out;
                    dma_addr_r <= std_logic_vector(dskpt(18 downto 1));
                    dma_data_r <= flop_data_out;
                    dma_we_r   <= '1';
                    dma_req_r  <= '1';
                    flop_override <= '0';   -- DSKDATR solo un ciclo
                    dma_state  <= D_REQ;

                when D_REQ =>
                    if dma_gnt = '1' then
                        dskpt_inc <= '1';
                        dma_state <= D_WAIT;
                    end if;

                when D_WAIT =>
                    dma_req_r <= '0';
                    dma_we_r  <= '0';
                    dskpt_inc <= '0';
                    flop_override <= '0';
                    dma_state <= D_IDLE;
            end case;
        end if;
    end process;

    dma_req  <= dma_req_r;
    dma_we   <= dma_we_r;
    dma_addr <= dma_addr_r;
    dma_data <= dma_data_r;

    blckint  <= '1' when flop_blckint = '1' and blck_prev = '0' else '0';
    syncint  <= flop_syncint;

end rtl;
