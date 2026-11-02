----------------------------------------------------------------------------------
-- phase13_top.vhd
-- A500 a 28.375 MHz: CPU FX68K, Chip RAM 512 KB en BRAM (ram_chip),
-- SRAM externa deshabilitada (Slow RAM se anadira despues), Copper/Denise/Blitter,
-- video_subsystem + HDMI y consola serie actual.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity phase13_top is
    Port (
        clk_50m     : in  std_logic;
        addr        : out std_logic_vector(18 downto 0);
        data_a      : inout std_logic_vector(7 downto 0);
        we_a        : out std_logic;
        oe_a        : out std_logic;
        ce_a        : out std_logic;
        data_b      : inout std_logic_vector(7 downto 0);
        we_b        : out std_logic;
        oe_b        : out std_logic;
        ce_b        : out std_logic;
        uart_rx_in  : in  std_logic;
        uart_tx_out : out std_logic;
        hdmi_tx_p   : out std_logic_vector(3 downto 0);
        hdmi_tx_n   : out std_logic_vector(3 downto 0)
    );
end phase13_top;

architecture rtl of phase13_top is

    signal clk_28m      : std_logic;
    signal clk_141m     : std_logic;
    signal pll_locked   : std_logic;
    signal reset_n      : std_logic := '0';
    signal system_ready : std_logic := '0';
    signal reset_cnt    : integer range 0 to 1000000 := 0;

    signal phi_cnt : unsigned(1 downto 0) := (others => '0');
    signal en_phi1 : std_logic := '0';
    signal en_phi2 : std_logic := '0';

    -- CPU
    signal cpu_addr     : std_logic_vector(31 downto 0);
    signal cpu_as       : std_logic;
    signal cpu_uds      : std_logic;
    signal cpu_lds      : std_logic;
    signal cpu_rw       : std_logic;
    signal cpu_dtack    : std_logic := '1';
    signal cpu_data_in  : std_logic_vector(15 downto 0);
    signal cpu_data_out : std_logic_vector(15 downto 0);
    signal cpu_halt     : std_logic;
    signal cpu_fc       : std_logic_vector(2 downto 0);
    signal cpu_vpa      : std_logic;
    signal cpu_ipl      : std_logic_vector(2 downto 0);

    -- ROM / RAM / CIA / chipset
    signal rom_data : std_logic_vector(15 downto 0);
    signal sel_rom  : std_logic;
    signal ram_data : std_logic_vector(15 downto 0);
    signal sel_ram  : std_logic;
    signal ram_we   : std_logic_vector(1 downto 0);

    signal sel_ciaa  : std_logic;
    signal sel_ciab  : std_logic;
    signal ciaa_data : std_logic_vector(7 downto 0);
    signal ciab_data : std_logic_vector(7 downto 0);
    signal ciaa_irq  : std_logic;
    signal ciab_irq  : std_logic;
    signal ciab_wdata: std_logic_vector(7 downto 0);
    signal ciab_prb  : std_logic_vector(7 downto 0) := (others => '1');
    signal dsk_stat  : std_logic_vector(3 downto 0) := "1111";
    signal dsk_prb_prev : std_logic_vector(7 downto 0) := (others => '1');
    signal dsk_cyl      : integer range 0 to 79 := 0;
    signal dsk_motor    : std_logic := '0';
    signal dsk_trk0     : std_logic := '0';

    -- Subsistema de disquetera (SRAM + ADF + Minimig paula_floppy)
    signal flop_dsk_status   : std_logic_vector(3 downto 0);
    signal flop_reg_data_out : std_logic_vector(15 downto 0);
    signal flop_dma_req      : std_logic := '0';
    signal flop_dma_we       : std_logic := '0';
    signal flop_dma_gnt      : std_logic := '0';
    signal flop_dma_addr     : std_logic_vector(18 downto 1);
    signal flop_dma_data     : std_logic_vector(15 downto 0);
    signal flop_blckint      : std_logic := '0';
    signal flop_syncint      : std_logic := '0';
    signal flop_adf_done     : std_logic := '0';
    signal flop_adf_timeout  : std_logic := '0';
    signal loader_active     : std_logic;
    signal cia_dsk_status    : std_logic_vector(3 downto 0);
    signal flop_read_data    : std_logic_vector(15 downto 0);
    signal flop_uart_tx      : std_logic;
    signal ram_dina          : std_logic_vector(15 downto 0);
    signal kbd_rx_in         : std_logic;

    signal sel_chipset : std_logic;
    signal intena      : std_logic_vector(14 downto 0) := (others => '0');
    signal intreq      : std_logic_vector(14 downto 0) := (others => '0');
    signal dmacon      : std_logic_vector(14 downto 0) := (others => '0');

    -- Video H/V y chipset
    signal h_cnt : integer range 0 to 1023 := 0;
    signal v_cnt : integer range 0 to 1023 := 0;

    signal blt_dma_req    : std_logic := '0';
    signal blt_rd_active  : std_logic := '0';
    signal blt_gnt        : std_logic := '0';
    signal blt_busy       : std_logic := '0';
    signal blt_busy_prev  : std_logic := '0';
    signal blt_zero       : std_logic := '0';
    signal blt_cpu_as     : std_logic := '1';
    signal blt_ram_addr_r : std_logic_vector(18 downto 1);
    signal blt_ram_addr_w : std_logic_vector(18 downto 1);
    signal blt_ram_data_w : std_logic_vector(15 downto 0);
    signal blt_ram_we_w   : std_logic_vector(1 downto 0);

    signal cop_dma_req    : std_logic := '0';
    signal cop_gnt        : std_logic := '0';
    signal cop_cpu_as     : std_logic := '1';
    signal cop_dma_enable : std_logic := '0';
    signal cop_ram_addr   : std_logic_vector(18 downto 1);
    signal cop_reg_addr   : std_logic_vector(8 downto 0);
    signal cop_reg_data   : std_logic_vector(15 downto 0);
    signal cop_reg_we     : std_logic := '0';

    signal ram_addr_mux : std_logic_vector(18 downto 1);
    signal portb_addr   : std_logic_vector(18 downto 1);

    signal denise_r  : std_logic_vector(7 downto 0);
    signal denise_g  : std_logic_vector(7 downto 0);
    signal denise_b  : std_logic_vector(7 downto 0);
    signal vram_addr : std_logic_vector(17 downto 0);
    signal dna_ddfstrt : std_logic_vector(7 downto 0);
    signal dna_ddfstop : std_logic_vector(7 downto 0);
    signal dna_lw      : std_logic_vector(7 downto 0);
    signal dna_nz      : std_logic_vector(15 downto 0);
    signal dna_col0    : std_logic_vector(11 downto 0);
    signal dna_col1    : std_logic_vector(11 downto 0);
    signal dna_pt      : std_logic_vector(15 downto 0);
    signal trace_tx    : std_logic;
    signal trace_active: std_logic;
    signal trace_cnt   : std_logic_vector(15 downto 0);
    signal trace_rd    : std_logic_vector(15 downto 0);
    signal trace_state : std_logic_vector(1 downto 0);
    signal ld_addr     : std_logic_vector(17 downto 0);
    signal ld_active   : std_logic;
    signal amiga_tx    : std_logic;
    signal vbl_cnt     : unsigned(15 downto 0) := (others => '0');
    signal pc_sample   : std_logic_vector(23 downto 0) := (others => '0');
    signal pc_div      : unsigned(21 downto 0) := (others => '0');
    signal vram_data : std_logic_vector(15 downto 0);
    signal chipset_we   : std_logic;
    signal chipset_addr : std_logic_vector(15 downto 0);
    signal chipset_data : std_logic_vector(15 downto 0);
    signal chipset_we2  : std_logic;
    signal vid_red      : std_logic_vector(7 downto 0) := (others => '0');
    signal vid_green    : std_logic_vector(7 downto 0) := (others => '0');
    signal vid_blue     : std_logic_vector(7 downto 0) := (others => '0');
    signal vid_hsync    : std_logic := '1';
    signal vid_vsync    : std_logic := '1';
    signal vid_blank    : std_logic := '1';

    -- Diagnostico de video / consola (display de 7 segmentos en pantalla)
    constant VIDEO_TEST : boolean := true;   -- true = video Denise arriba + diagnostico abajo
    constant TEST_CARD  : boolean := false;  -- true = carta de ajuste a pantalla completa
    constant SER_ECHO   : boolean := true;   -- true = reenvia por TX cada byte recibido
    signal frame_cnt    : unsigned(7 downto 0) := (others => '0');
    signal echo_wr      : std_logic := '0';
    signal bplcon0_reg  : std_logic_vector(15 downto 0) := (others => '0');
    signal dmacon16     : std_logic_vector(15 downto 0);
    signal bplcon0_lat  : std_logic_vector(15 downto 0) := (others => '0');
    signal dmacon_lat   : std_logic_vector(15 downto 0) := (others => '0');
    signal rd_cnt       : unsigned(15 downto 0) := (others => '0');
    signal rd_cnt_lat   : std_logic_vector(15 downto 0) := (others => '0');
    signal rx_byte_lat  : std_logic_vector(7 downto 0) := (others => '0');
    signal serdatr_rd_lat : std_logic_vector(15 downto 0) := (others => '0');
    signal intreq16     : std_logic_vector(15 downto 0);
    signal intena16     : std_logic_vector(15 downto 0);
    signal intreq_lat   : std_logic_vector(15 downto 0) := (others => '0');
    signal intena_lat   : std_logic_vector(15 downto 0) := (others => '0');
    signal bfe001_rd_lat   : std_logic_vector(15 downto 0) := (others => '0');
    signal cop1lc_wr       : unsigned(15 downto 0) := (others => '0');
    signal cop1lc_wr_lat   : std_logic_vector(15 downto 0) := (others => '0');
    signal cop_move        : unsigned(15 downto 0) := (others => '0');
    signal cop_move_lat    : std_logic_vector(15 downto 0) := (others => '0');
    signal cop_ir1         : std_logic_vector(15 downto 0);
    signal cop_ir2         : std_logic_vector(15 downto 0);
    signal bpl_cop_cnt     : unsigned(15 downto 0) := (others => '0');
    signal bpl_cop_data    : std_logic_vector(15 downto 0) := (others => '0');
    signal cop_ir1_lat     : std_logic_vector(15 downto 0) := (others => '0');
    signal cop_ir2_lat     : std_logic_vector(15 downto 0) := (others => '0');
    signal cop_pc          : std_logic_vector(17 downto 0);
    signal cop_lc          : std_logic_vector(31 downto 0);
    signal cop2lc_v        : std_logic_vector(31 downto 0);
    signal ser_rbf_pulse : std_logic := '0';
    signal ser_rbf_clear : std_logic := '0';

    signal v_pos        : integer range 0 to 523 := 0;
    signal h_pos        : integer range 0 to 221 := 0;
    signal vblank       : std_logic := '0';
    signal vblank_pulse : std_logic := '0';
    signal vposr_reg    : std_logic_vector(15 downto 0) := (others => '0');
    signal vhposr_reg   : std_logic_vector(15 downto 0) := (others => '0');

    -- ERSY (BPLCON0 bit 1). Con un genlock ausente, el contador de haz que
    -- lee la CPU (VPOSR/VHPOSR) se congela mientras ERSY esta a 1. El ROM de
    -- arranque de Kickstart 1.3 lo usa para detectar genlock: pone ERSY, lee
    -- VHPOSR dos veces y concluye "sin genlock" solo si el valor no cambia.
    -- Si no se congela, el ROM cree que hay genlock y deja ERSY|GAFF (0x0102)
    -- en BPLCON0, que acaba en las copper lists (0x0302 en vez de 0x0200).
    signal ersy_prev    : std_logic := '0';
    signal ersy_v_lat   : unsigned(8 downto 0) := (others => '0');
    signal ersy_h_lat   : unsigned(7 downto 0) := (others => '0');
    signal vposr_rd     : std_logic_vector(15 downto 0) := (others => '0');
    signal vhposr_rd    : std_logic_vector(15 downto 0) := (others => '0');

    signal overlay   : std_logic := '1';
    signal bus_state : integer range 0 to 3 := 0;

    -- SERDAT / UART / teclado
    signal serdat_byte     : std_logic_vector(7 downto 0) := (others => '0');
    signal serdat_wr       : std_logic := '0';
    signal serdat_hit      : std_logic := '0';
    signal serdat_hit_prev : std_logic := '0';
    signal serdat_tbe      : std_logic;
    signal serdatr_val     : std_logic_vector(15 downto 0);
    signal serdatr_data    : std_logic_vector(7 downto 0) := (others => '0');
    signal serdatr_ovrun   : std_logic := '0';
    signal serdatr_read_cycle : std_logic := '0';
    signal ser_rx_data     : std_logic_vector(7 downto 0);
    signal ser_rx_valid    : std_logic;
    signal kbd_scancode    : std_logic_vector(7 downto 0);
    signal kbd_cia_byte    : std_logic_vector(7 downto 0);
    signal kbd_cia_valid   : std_logic;
    signal kbd_inj_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal kbd_inj_valid   : std_logic := '0';
    signal kbd_inj_code    : std_logic_vector(6 downto 0) := (others => '0');
    signal kbd_inj_state   : integer range 0 to 2 := 0;
    signal kbd_inj_delay   : integer range 0 to 1048575 := 0;
    signal kbd_valid       : std_logic;

    signal dbg_tod       : std_logic_vector(7 downto 0);
    signal dbg_timer_run : std_logic_vector(1 downto 0);

    -- [ILA] Senales marcadas para el analizador logico de Vivado
    -- (Herramientas -> Set up Debug en el diseno sintetizado)
    attribute mark_debug : string;
    attribute mark_debug of cop_pc        : signal is "true";
    attribute mark_debug of cop_ram_addr  : signal is "true";
    attribute mark_debug of vram_data     : signal is "true";
    attribute mark_debug of cop_ir1       : signal is "true";
    attribute mark_debug of cop_ir2       : signal is "true";
    attribute mark_debug of cop_reg_we    : signal is "true";
    attribute mark_debug of cop_reg_addr  : signal is "true";
    attribute mark_debug of cop_reg_data  : signal is "true";
    attribute mark_debug of cop_dma_req   : signal is "true";
    attribute mark_debug of cop_gnt       : signal is "true";
    attribute mark_debug of cop_dma_enable: signal is "true";
    attribute mark_debug of blt_busy      : signal is "true";

begin

    -- Clocks
    inst_clocks : entity work.clk_wiz_0
        port map (
            clk_in1  => clk_50m,
            reset    => '0',
            clk_out1 => clk_28m,
            clk_out2 => clk_141m,
            locked   => pll_locked
        );

    reset_n <= pll_locked;

    process(clk_28m, reset_n)
    begin
        if reset_n = '0' then
            reset_cnt    <= 0;
            system_ready <= '0';
            overlay      <= '1';
        elsif rising_edge(clk_28m) then
            if reset_cnt < 1000000 then
                reset_cnt    <= reset_cnt + 1;
                system_ready <= '0';
            else
                -- La Amiga arranca YA (mano visible ~4 s). El ADF se carga
                -- en segundo plano y se "inserta" al terminar.
                system_ready <= '1';
            end if;
            if bus_state = 3 and cpu_rw = '0' and
               cpu_addr(23 downto 12) = x"BFE" then
                overlay <= '0';
            end if;
        end if;
    end process;

    -- PHI: 28.375 MHz / 4 = 7.09 MHz
    process(clk_28m)
    begin
        if rising_edge(clk_28m) then
            phi_cnt <= phi_cnt + 1;
            en_phi1 <= '0';
            en_phi2 <= '0';
            if phi_cnt = "00" then en_phi1 <= '1'; end if;
            if phi_cnt = "10" then en_phi2 <= '1'; end if;
        end if;
    end process;

    -- Address decode
    sel_ram <= '1' when cpu_addr(23 downto 19) = "00000" and
               (overlay = '0' or cpu_rw = '0') else '0';
    sel_rom <= '1' when cpu_addr(23 downto 19) = "11111" else
               '1' when overlay = '1' and cpu_rw = '1' and
               cpu_addr(23 downto 19) = "00000" else '0';

    -- DMA de disco: tiene prioridad sobre CPU/blitter en el puerto A. Solo
    -- se concede cuando la CPU esta en reposo (bus_state=0), asi que no hay
    -- conflicto con una fase de datos.
    flop_dma_gnt <= '1' when bus_state = 0 and flop_dma_req = '1' else '0';

    ram_we(1) <= '1' when flop_dma_gnt = '1' else
                 '1' when sel_ram = '1' and cpu_rw = '0' and
                 cpu_uds = '0' and bus_state = 3 else '0';
    ram_we(0) <= '1' when flop_dma_gnt = '1' else
                 '1' when sel_ram = '1' and cpu_rw = '0' and
                 cpu_lds = '0' and bus_state = 3 else '0';

    ram_dina <= flop_dma_data when flop_dma_gnt = '1' else cpu_data_out;

    sel_ciaa <= '1' when cpu_addr(23 downto 12) = x"BFE" else '0';
    sel_ciab <= '1' when cpu_addr(23 downto 12) = x"BFD" else '0';
    sel_chipset <= '1' when cpu_addr(23 downto 16) = x"DF" else '0';

    -- El blitter recibe un "/AS" sintetico que solo baja durante la fase de
    -- escritura con datos estables (bus_state = 3); internamente detecta el
    -- flanco y registra UNA sola escritura por ciclo de bus.
    blt_cpu_as <= '0' when chipset_we = '1' else '1';
    cop_cpu_as <= cpu_as when sel_chipset = '1' else '1';
    cop_dma_enable <= dmacon(9) and dmacon(7);

    -- El Copper lee por el puerto B con prioridad: asi ningun blit largo
    -- bloquea la ejecucion de la Copper list al inicio del frame (v_cnt=0..44)
    -- ni le cambia portb_addr en mitad de un FETCH1..FETCH6.
    cop_gnt <= '1';
    -- El blitter puede iniciar una lectura por el puerto A (o escritura por B)
    -- cuando la CPU esta en los estados 0/1 del ciclo de bus y el Copper no
    -- esta usando el puerto B (cop_dma_req = '0').
    blt_gnt <= '1' when (bus_state = 0 or bus_state = 1) and
                        cop_dma_req = '0' and flop_dma_gnt = '0' else '0';

    -- Puerto A: prioridad DMA de disco, luego lectura del blitter, luego CPU.
    ram_addr_mux <= flop_dma_addr  when flop_dma_gnt = '1' else
                    blt_ram_addr_r when blt_rd_active = '1' else
                    cpu_addr(18 downto 1);

    -- Puerto B = bus del chipset. Prioridad: escritura activa del blitter
    -- (solo en el ciclo con blt_ram_we_w /= "00"), luego la lectura de la
    -- copper list, luego la lectura de bitplanes de Denise.
    portb_addr <= ld_addr when ld_active = '1' else
                  blt_ram_addr_w when blt_ram_we_w /= "00" else
                  cop_ram_addr   when cop_dma_req = '1' else
                  vram_addr;

    chipset_we   <= '1' when sel_chipset = '1' and cpu_rw = '0' and bus_state = 3 else '0';
    chipset_addr <= x"F" & "000" & cop_reg_addr when cop_reg_we = '1' else cpu_addr(15 downto 0);
    chipset_data <= cop_reg_data                when cop_reg_we = '1' else cpu_data_out;
    chipset_we2  <= cop_reg_we or chipset_we;
    dmacon16     <= '0' & dmacon;
    intreq16     <= '0' & intreq;
    intena16     <= '0' & intena;
    echo_wr      <= ser_rx_valid when SER_ECHO else '0';

    -- El teclado Amiga entrega el byte invertido y rotado: DiagROM hace
    -- "ror.b #1 / not.b" al leerlo, asi que hay que presentar NOT(ROL(k,1)).
    kbd_cia_byte <= kbd_inj_byte when kbd_inj_state /= 0 else
                    not (kbd_scancode(6 downto 0) & kbd_scancode(7));
    kbd_cia_valid <= kbd_inj_valid or kbd_valid;

    -- Cada caracter que llega por el puerto serie se convierte en una
    -- pulsacion real del teclado Amiga (pulsar y soltar). Asi el menu de
    -- DiagROM no depende de su consola serie ni del modo ANSI.
    process(clk_28m, system_ready)
        variable sc : std_logic_vector(7 downto 0);
    begin
        if system_ready = '0' then
            kbd_inj_valid <= '0';
            kbd_inj_byte  <= (others => '0');
            kbd_inj_state <= 0;
            kbd_inj_delay <= 0;
        elsif rising_edge(clk_28m) then
            kbd_inj_valid <= '0';
            case ser_rx_data is
                when x"31" => sc := x"01";
                when x"32" => sc := x"02";
                when x"33" => sc := x"03";
                when x"34" => sc := x"04";
                when x"35" => sc := x"05";
                when x"36" => sc := x"06";
                when x"37" => sc := x"07";
                when x"38" => sc := x"08";
                when x"39" => sc := x"09";
                when x"30" => sc := x"0A";
                when x"20" => sc := x"40";
                when x"0D" => sc := x"43";
                when x"0A" => sc := x"43";
                when x"73" => sc := x"21";
                when x"61" => sc := x"20";
                when x"6D" => sc := x"37";
                when x"79" => sc := x"15";
                when x"6E" => sc := x"36";
                when others => sc := x"FF";
            end case;

            case kbd_inj_state is
                when 0 =>
                    if ser_rx_valid = '1' and sc /= x"FF" then
                        kbd_inj_byte  <= not (sc(6 downto 0) & '0');
                        kbd_inj_valid <= '1';
                        kbd_inj_code  <= sc(6 downto 0);
                        kbd_inj_state <= 1;
                        kbd_inj_delay <= 0;
                    end if;
                when 1 =>
                    kbd_inj_delay <= kbd_inj_delay + 1;
                    if kbd_inj_delay = 200000 then
                        kbd_inj_byte  <= not (kbd_inj_code & '1');
                        kbd_inj_valid <= '1';
                        kbd_inj_state <= 2;
                        kbd_inj_delay <= 0;
                    end if;
                when others =>
                    kbd_inj_delay <= kbd_inj_delay + 1;
                    if kbd_inj_delay = 100000 then
                        kbd_inj_state <= 0;
                    end if;
            end case;
        end if;
    end process;

    cpu_vpa <= '0' when cpu_fc = "111" else '0' when sel_ciaa = '1' else '1';

    -- Bus state machine (28.375 MHz, en_phi1)
    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            bus_state <= 0;
            cpu_dtack <= '1';
        elsif rising_edge(clk_28m) then
            if en_phi1 = '1' then
                case bus_state is
                    when 0 =>
                        cpu_dtack <= '1';
                        if cpu_as = '0' and cpu_fc /= "111" then
                            bus_state <= 1;
                        end if;
                    when 1 => bus_state <= 2;
                    when 2 =>
                        cpu_dtack <= '0';
                        bus_state <= 3;
                    when 3 =>
                        cpu_dtack <= '0';
                        if cpu_as = '1' then
                            cpu_dtack <= '1';
                            bus_state <= 0;
                        end if;
                    when others => bus_state <= 0;
                end case;
            end if;
        end if;
    end process;

    -- CPU data in
    cpu_data_in <= rom_data when sel_rom = '1' else
                   ram_data when sel_ram = '1' else
                   x"FF" & ciaa_data when sel_ciaa = '1' else
                   ciab_data & x"FF" when sel_ciab = '1' else
                   -- DMACONR ($DFF002): bit15 = 0, bit14 = BBUSY,
                   -- bit13 = BZERO, bits12..0 = DMACON.
                   -- Antes se ponia blt_busy en el bit15, asi que WaitBlit
                   -- (que mira el bit14) veia el blitter siempre libre y la CPU
                   -- podia pisar un blit en curso.
                   '0' & blt_busy & blt_zero & dmacon(12 downto 0)
                        when sel_chipset = '1' and cpu_addr(8 downto 1) = x"01" else
                   -- INTENAR = $DFF01C (idx $0E), INTREQR = $DFF01E (idx $0F)
                   '0' & intena when sel_chipset = '1' and cpu_addr(8 downto 1) = x"0E" else
                   '0' & intreq when sel_chipset = '1' and cpu_addr(8 downto 1) = x"0F" else
                   vposr_rd when sel_chipset = '1' and cpu_addr(8 downto 1) = x"02" else
                   vhposr_rd when sel_chipset = '1' and cpu_addr(8 downto 1) = x"03" else
                   serdatr_val when sel_chipset = '1' and cpu_addr(8 downto 1) = x"0C" else
                   -- DSKBYTR ($DFF01A, idx $0D) y DSKDATR ($DFF008, idx $04)
                   -- los genera el subsistema de disquetera (paula_floppy).
                   flop_read_data when sel_chipset = '1' and
                       (cpu_addr(8 downto 1) = x"0D" or cpu_addr(8 downto 1) = x"04") else
                   x"FFFF";

    -- ROM 256 KB (diagrom)
    inst_rom : entity work.rom_diagrom
        port map (
            clka  => clk_28m,
            addra => cpu_addr(17 downto 1),
            douta => rom_data
        );

    -- Contadores de haz. Se ajustan EXACTAMENTE al marco DVI para que la
    -- imagen no "patine": 222 ciclos de color x 4 = 888 ciclos por linea
    -- (igual que h_cnt) y 524 lineas por campo (igual que v_cnt).
    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            h_pos <= 0; v_pos <= 0; vblank <= '0';
        elsif rising_edge(clk_28m) then
            if en_phi1 = '1' then
                if h_pos = 221 then
                    h_pos <= 0;
                    if v_pos = 523 then v_pos <= 0; else v_pos <= v_pos + 1; end if;
                else
                    h_pos <= h_pos + 1;
                end if;
                if v_pos < 26 then vblank <= '1'; else vblank <= '0'; end if;
                if v_pos = 0 and h_pos = 0 then vblank_pulse <= '1';
                else vblank_pulse <= '0'; end if;
                vposr_reg  <= "0000000" & std_logic_vector(to_unsigned(v_pos mod 512, 9));
                vhposr_reg <= std_logic_vector(to_unsigned(v_pos mod 256, 8)) &
                             std_logic_vector(to_unsigned(h_pos, 8));
            end if;
        end if;
    end process;

    -- Congelacion de la lectura de VPOSR/VHPOSR mientras ERSY esta activo.
    -- El contador interno sigue corriendo (el Copper usa v_pos/h_pos, no
    -- estos registros); solo se congela lo que ve la CPU, que es justo lo
    -- que comprueba el sondeo de genlock del ROM.
    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            ersy_prev  <= '0';
            ersy_v_lat <= (others => '0');
            ersy_h_lat <= (others => '0');
        elsif rising_edge(clk_28m) then
            ersy_prev <= bplcon0_reg(1);
            if bplcon0_reg(1) = '1' and ersy_prev = '0' then
                ersy_v_lat <= to_unsigned(v_pos mod 512, 9);
                ersy_h_lat <= to_unsigned(h_pos, 8);
            end if;
        end if;
    end process;

    vposr_rd  <= "0000000" & std_logic_vector(ersy_v_lat)
                 when bplcon0_reg(1) = '1' else vposr_reg;
    vhposr_rd <= std_logic_vector(ersy_v_lat(7 downto 0)) &
                 std_logic_vector(ersy_h_lat)
                 when bplcon0_reg(1) = '1' else vhposr_reg;

    -- Contador de frames y captura de registros para el diagnostico
    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            frame_cnt   <= (others => '0');
            rx_byte_lat <= (others => '0');
            rd_cnt_lat  <= (others => '0');
            bplcon0_lat <= (others => '0');
            dmacon_lat  <= (others => '0');
            intreq_lat  <= (others => '0');
            intena_lat  <= (others => '0');
            bfe001_rd_lat <= (others => '0');
            cop1lc_wr     <= (others => '0');
            cop1lc_wr_lat <= (others => '0');
            cop_move      <= (others => '0');
            cop_move_lat  <= (others => '0');
            cop_ir1_lat   <= (others => '0');
            cop_ir2_lat   <= (others => '0');
            bpl_cop_cnt   <= (others => '0');
            bpl_cop_data  <= (others => '0');
        elsif rising_edge(clk_28m) then
            if h_cnt = 887 and v_cnt = 523 then
                frame_cnt <= frame_cnt + 1;
            end if;
            -- Lo que la CPU lee de PRA ($BFE001): para ver el estado de los botones
            if sel_ciaa = '1' and cpu_as = '0' and cpu_rw = '1' and
               cpu_addr(11 downto 8) = x"0" then
                bfe001_rd_lat <= cpu_data_in;
            end if;
            -- ¿DiagROM ha escrito COP1LC? (lo hace solo si dibuja pantalla)
            if chipset_we2 = '1' and
               (chipset_addr(8 downto 1) = x"40" or chipset_addr(8 downto 1) = x"41") then
                cop1lc_wr <= cop1lc_wr + 1;
            end if;
            -- Escrituras del Copper a BPLCON0: contador + ultimo valor (estable)
            if cop_reg_we = '1' and cop_reg_addr(8) = '1' and cop_reg_addr(7 downto 0) = x"00" then
                bpl_cop_cnt  <= bpl_cop_cnt + 1;
                bpl_cop_data <= cop_reg_data;
            end if;
            -- MOVEs ejecutados por el Copper: guarda la instruccion ejecutada
            if cop_reg_we = '1' then
                cop_move    <= cop_move + 1;
                cop_ir1_lat <= cop_ir1;
                cop_ir2_lat <= cop_ir2;
            end if;
            if vblank_pulse = '1' then
                bplcon0_lat <= bplcon0_reg;
                dmacon_lat  <= dmacon16;
                rd_cnt_lat  <= std_logic_vector(rd_cnt);
                intreq_lat  <= intreq16;
                intena_lat  <= intena16;
                cop1lc_wr_lat <= std_logic_vector(cop1lc_wr);
                cop_move_lat  <= std_logic_vector(cop_move);
            end if;
        end if;
    end process;

    -- Video timing 888x524 a 28.375 MHz + diagnostico en pantalla
    --   Arriba (y 0..295)  : video real de Denise (ancho completo)
    --   Fila A (y 296..352): BPLCON0 (4 digitos, verde) + DMACON (4, amarillo)
    --   Fila B (y 360..416): lecturas de SERDATR (4, cian) + byte leido (4, magenta)
    --   Fila C (y 424..480): escrituras del Copper a BPLCON0 (naranja) + valor (gris)
    process(clk_28m)
        variable bar_r, bar_g, bar_b : std_logic_vector(7 downto 0);
        variable y      : integer range 0 to 63;
        variable band   : integer range 0 to 2;
        variable idx    : integer range 0 to 8;
        variable xo     : integer range 0 to 71;
        variable dv     : std_logic_vector(3 downto 0);
        variable segs   : std_logic_vector(6 downto 0);
        variable seg_on : std_logic;
        variable digit_on : std_logic;
        variable in_band  : boolean;
        variable col_r, col_g, col_b : std_logic_vector(7 downto 0);
        variable mv_x   : integer range 0 to 607;

        function seg7(v : std_logic_vector(3 downto 0)) return std_logic_vector is
            variable s : std_logic_vector(6 downto 0);
        begin
            case v is
                when x"0" => s := "1111110";
                when x"1" => s := "0110000";
                when x"2" => s := "1101101";
                when x"3" => s := "1111001";
                when x"4" => s := "0110011";
                when x"5" => s := "1011011";
                when x"6" => s := "1011111";
                when x"7" => s := "1110000";
                when x"8" => s := "1111111";
                when x"9" => s := "1111011";
                when x"A" => s := "1110111";
                when x"B" => s := "0011111";
                when x"C" => s := "1001110";
                when x"D" => s := "0111101";
                when x"E" => s := "1001111";
                when others => s := "1000111";
            end case;
            return s;
        end function;

    begin
        if rising_edge(clk_28m) then
            -- El marco DVI arranca a la vez que los contadores de haz del
            -- Amiga (h_pos/v_pos, que se reinician con system_ready). Asi la
            -- linea Amiga N se ve siempre en la linea DVI N. Antes el marco
            -- DVI corria desde la configuracion de la FPGA y quedaba ~78
            -- lineas desfasado: la parte baja de la mano caia debajo de la
            -- franja de diagnostico (v_cnt >= 296).
            if system_ready = '0' then
                h_cnt <= 0;
                v_cnt <= 0;
            elsif h_cnt < 887 then
                h_cnt <= h_cnt + 1;
            else
                h_cnt <= 0;
                if v_cnt < 523 then v_cnt <= v_cnt + 1; else v_cnt <= 0; end if;
            end if;

            if h_cnt >= 186 and h_cnt < 210 then vid_hsync <= '0'; else vid_hsync <= '1'; end if;
            if v_cnt >= 476 and v_cnt < 478 then vid_vsync <= '0'; else vid_vsync <= '1'; end if;

            -- Barras de color de fondo (mismas que el proyecto video_test)
            if    h_cnt <  80 then bar_r := x"FF"; bar_g := x"FF"; bar_b := x"FF";
            elsif h_cnt < 160 then bar_r := x"FF"; bar_g := x"FF"; bar_b := x"00";
            elsif h_cnt < 240 then bar_r := x"00"; bar_g := x"FF"; bar_b := x"FF";
            elsif h_cnt < 320 then bar_r := x"00"; bar_g := x"FF"; bar_b := x"00";
            elsif h_cnt < 400 then bar_r := x"FF"; bar_g := x"00"; bar_b := x"FF";
            elsif h_cnt < 480 then bar_r := x"FF"; bar_g := x"00"; bar_b := x"00";
            elsif h_cnt < 560 then bar_r := x"00"; bar_g := x"00"; bar_b := x"FF";
            else                    bar_r := x"00"; bar_g := x"00"; bar_b := x"00";
            end if;

            mv_x := (to_integer(frame_cnt) * 4) mod 608;

            if v_cnt >= 296 and v_cnt < 352 then
                in_band := true;  band := 0; y := v_cnt - 296;
            elsif v_cnt >= 360 and v_cnt < 416 then
                in_band := true;  band := 1; y := v_cnt - 360;
            elsif v_cnt >= 424 and v_cnt < 480 then
                in_band := true;  band := 2; y := v_cnt - 424;
            else
                in_band := false; band := 0; y := 0;
            end if;

            if h_cnt < 640 and v_cnt < 480 then
                vid_blank <= '0';
                if TEST_CARD then
                    -- Carta de ajuste: borde, rejilla cada 32 px y cruz central
                    if h_cnt < 4 or h_cnt >= 636 or v_cnt < 4 or v_cnt >= 476 then
                        vid_red <= x"FF"; vid_green <= x"FF"; vid_blue <= x"FF";
                    elsif h_cnt = 320 or v_cnt = 240 then
                        vid_red <= x"FF"; vid_green <= x"00"; vid_blue <= x"00";
                    elsif (h_cnt mod 32) = 0 or (v_cnt mod 32) = 0 then
                        vid_red <= x"20"; vid_green <= x"FF"; vid_blue <= x"20";
                    elsif (h_cnt mod 160) < 2 and (v_cnt mod 120) < 2 then
                        vid_red <= x"FF"; vid_green <= x"FF"; vid_blue <= x"00";
                    else
                        vid_red <= x"00"; vid_green <= x"00"; vid_blue <= x"00";
                    end if;
                elsif VIDEO_TEST then
                    if in_band and h_cnt >= 16 and h_cnt < 592 then
                        idx := (h_cnt - 16) / 72;
                        xo  := (h_cnt - 16) mod 72;
                        if idx <= 7 and xo < 40 then
                            digit_on := '1';
                            if band = 0 then
                                case idx is
                                    -- Fila A: bus de direcciones del 68000 (PC)
                                    -- Fila A: BPLCON0 + BPL1PT (parte baja)
                                    when 0 => dv := bplcon0_lat(15 downto 12);
                                    when 1 => dv := bplcon0_lat(11 downto 8);
                                    when 2 => dv := bplcon0_lat(7 downto 4);
                                    when 3 => dv := bplcon0_lat(3 downto 0);
                                    when 4 => dv := dna_pt(15 downto 12);
                                    when 5 => dv := dna_pt(11 downto 8);
                                    when 6 => dv := dna_pt(7 downto 4);
                                    when others => dv := dna_pt(3 downto 0);
                                end case;
                                if idx <= 5 then col_r := x"00"; col_g := x"FF"; col_b := x"00";
                                else              col_r := x"FF"; col_g := x"FF"; col_b := x"00"; end if;
                            elsif band = 1 then
                                case idx is
                                    -- Fila B: captura de bus
                                    --   0-3 = registros capturados (wr_idx)
                                    --   4-5 = registros volcados (rd_idx)
                                    --   6   = estado (0 captura, 1 volcado, 2 fin)
                                    --   7   = activo (volcando)
                                    when 0 => dv := std_logic_vector(vbl_cnt(15 downto 12));
                                    when 1 => dv := std_logic_vector(vbl_cnt(11 downto 8));
                                    when 2 => dv := std_logic_vector(vbl_cnt(7 downto 4));
                                    when 3 => dv := std_logic_vector(vbl_cnt(3 downto 0));
                                    when 4 => dv := pc_sample(23 downto 20);
                                    when 5 => dv := pc_sample(19 downto 16);
                                    when 6 => dv := pc_sample(15 downto 12);
                                    when 7 => dv := pc_sample(11 downto 8);
                                    when others => dv := "0000"; digit_on := '0';
                                end case;
                                if idx <= 3 then col_r := x"00"; col_g := x"FF"; col_b := x"FF";
                                else              col_r := x"FF"; col_g := x"00"; col_b := x"FF"; end if;
                            else
                                case idx is
                                    -- Fila C (diagnostico de la mano):
                                    --   izquierda = COLOR01 (0FFF = aun blanca)
                                    --   derecha   = contador de palabras de
                                    --               bitplane distintas de cero
                                    when 0 => dv := "0000";
                                    when 1 => dv := dna_col1(11 downto 8);
                                    when 2 => dv := dna_col1(7 downto 4);
                                    when 3 => dv := dna_col1(3 downto 0);
                                    when 4 => dv := dna_nz(15 downto 12);
                                    when 5 => dv := dna_nz(11 downto 8);
                                    when 6 => dv := dna_nz(7 downto 4);
                                    when others => dv := dna_nz(3 downto 0);
                                end case;
                                if idx <= 3 then col_r := x"FF"; col_g := x"40"; col_b := x"00";
                                else              col_r := x"C0"; col_g := x"C0"; col_b := x"C0"; end if;
                            end if;

                            segs   := seg7(dv);
                            seg_on := '0';
                            if y < 8  and xo >= 8  and xo < 32 and segs(6) = '1' then seg_on := '1'; end if;
                            if y >= 8  and y < 28 and xo >= 32 and xo < 40 and segs(5) = '1' then seg_on := '1'; end if;
                            if y >= 28 and y < 48 and xo >= 32 and xo < 40 and segs(4) = '1' then seg_on := '1'; end if;
                            if y >= 48 and y < 56 and xo >= 8  and xo < 32 and segs(3) = '1' then seg_on := '1'; end if;
                            if y >= 28 and y < 48 and xo < 8 and segs(2) = '1' then seg_on := '1'; end if;
                            if y >= 8  and y < 28 and xo < 8 and segs(1) = '1' then seg_on := '1'; end if;
                            if y >= 24 and y < 32 and xo >= 8  and xo < 32 and segs(0) = '1' then seg_on := '1'; end if;

                            if digit_on = '1' and seg_on = '1' then
                                vid_red <= col_r; vid_green <= col_g; vid_blue <= col_b;
                            else
                                vid_red <= x"08"; vid_green <= x"08"; vid_blue <= x"10";
                            end if;
                        else
                            vid_red <= bar_r; vid_green <= bar_g; vid_blue <= bar_b;
                        end if;
                    elsif v_cnt < 296 then
                        -- Salida en vivo de Denise (mitad superior de la pantalla)
                        vid_red   <= denise_r;
                        vid_green <= denise_g;
                        vid_blue  <= denise_b;
                    elsif v_cnt >= 208 and v_cnt < 240 and
                          h_cnt >= mv_x and h_cnt < mv_x + 32 then
                        vid_red <= x"FF"; vid_green <= x"00"; vid_blue <= x"00";
                    else
                        vid_red <= bar_r; vid_green <= bar_g; vid_blue <= bar_b;
                    end if;
                else
                    vid_red   <= denise_r;
                    vid_green <= denise_g;
                    vid_blue  <= denise_b;
                end if;
            else
                vid_blank <= '1';
                vid_red   <= (others => '0');
                vid_green <= (others => '0');
                vid_blue  <= (others => '0');
            end if;
        end if;
    end process;

    -- Muestreo lento del PC del 68000 (legible en el panel de 7 segmentos)
    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            pc_sample <= (others => '0');
            pc_div    <= (others => '0');
        elsif rising_edge(clk_28m) then
            pc_div <= pc_div + 1;
            if pc_div = 0 then
                pc_sample <= cpu_addr(23 downto 0);
            end if;
        end if;
    end process;

    -- INTENA/INTREQ/DMACON
    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            intena <= (others => '0');
            intreq <= (others => '0');
            dmacon <= (others => '0');
            blt_busy_prev <= '0';
        elsif rising_edge(clk_28m) then
            if ser_rbf_clear = '1' then intreq(11) <= '0'; end if;   -- leido SERDATR
            if chipset_we2 = '1' then
                case chipset_addr(8 downto 1) is
                    when x"4B" =>
                        if chipset_data(15) = '1' then dmacon <= dmacon or chipset_data(14 downto 0);
                        else dmacon <= dmacon and not chipset_data(14 downto 0); end if;
                    when x"4D" =>
                        if chipset_data(15) = '1' then intena <= intena or chipset_data(14 downto 0);
                        else intena <= intena and not chipset_data(14 downto 0); end if;
                    when x"4E" =>
                        if chipset_data(15) = '1' then intreq <= intreq or chipset_data(14 downto 0);
                        else intreq <= intreq and not chipset_data(14 downto 0); end if;
                    when x"80" =>      -- BPLCON0 ($DFF100)
                        bplcon0_reg <= chipset_data;
                    when others => null;
                end case;
            end if;
            -- Las fuentes hardware de interrupcion se evaluan DESPUES de
            -- chipset_we2 para que un pulso de fin de blit o VBLANK no se
            -- pierda si coincide con los 4 ciclos de una escritura CPU a INTREQ.
            blt_busy_prev <= blt_busy;
            if blt_busy_prev = '1' and blt_busy = '0' then
                intreq(6) <= '1';
            end if;
            if vblank_pulse = '1' then
                intreq(5) <= '1';
                vbl_cnt   <= vbl_cnt + 1;
            end if;
            if ser_rbf_pulse = '1' then intreq(11) <= '1'; end if;   -- byte nuevo gana
            if ciab_irq = '1' then intreq(13) <= '1'; end if;        -- EXTER (CIA-B)
            if ciaa_irq = '1' then intreq(3) <= '1'; end if;
            -- Fin de DMA de disco (DSKBLK, bit 1). El subsistema ya lo
            -- entrega como pulso de un ciclo.
            if flop_blckint = '1' and flop_adf_done = '1' then
                intreq(1) <= '1';
            end if;
            -- (no se fuerza BPLEN: el software debe poder desactivar el DMA de
            --  bitplanes; Denise no depende de este bit para pintar)
        end if;
    end process;

    -- IRQ levels (CIA-A nivel 6, CIA-B nivel 2, RBF serie nivel 1)
    -- IPL activo a nivel bajo: nivel 6 = "001", 5 = "010", 3 = "100",
    -- 2 = "101", 1 = "110"; sin interrupcion = "111".
    cpu_ipl <= "001" when (intreq(13) = '1' and intena(13) = '1' and intena(14) = '1') else
               "010" when (intreq(11) = '1' and intena(11) = '1' and intena(14) = '1') else
               "100" when ((intreq(5) = '1' and intena(5) = '1') or
                           (intreq(4) = '1' and intena(4) = '1') or
                           (intreq(6) = '1' and intena(6) = '1')) and intena(14) = '1' else
               "101" when (intreq(3) = '1' and intena(3) = '1' and intena(14) = '1') else
               "110" when ((intreq(0) = '1' and intena(0) = '1') or
                           (intreq(1) = '1' and intena(1) = '1') or
                           (intreq(2) = '1' and intena(2) = '1')) and intena(14) = '1' else
               "111";

    -- Modelo minimo de la disquetera DF0 (unidad interna, sin medio).
    -- La FPGA no tiene mecanismo, pero Kickstart 1.3 sondea la unidad con la
    -- secuencia real: selecciona DF0, da pulsos de STEP y observa /TRK0 y
    -- /RDY (con el motor parado, /RDY de DF0 copia /TRK0). Por eso hay que
    -- llevar la pista, no basta con devolver un estado fijo.
    --   - /SEL0=1: no seleccionada -> lineas inactivas (todo 1).
    --   - Flanco de bajada de /SEL0: se latcha el estado de /MTR (como el
    --     hardware real: el motor solo cambia al seleccionar la unidad).
    --   - Flanco de bajada de /STEP estando seleccionada: la cabeza se mueve
    --     una pista; /DIR=0 hacia dentro (pista+1), /DIR=1 hacia fuera.
    --     En la pista 0 los pulsos hacia fuera no mueven (sensor /TRK0).
    --   - /TRK0 = 0 solo en la pista 0.
    --   - Motor parado: /RDY copia /TRK0. Motor en marcha: /RDY=1 (sin disco).
    --   - /WPRO=1 (sin proteccion), /CHNG=0 (sin disco, cambio asserted).
    -- Orden: (3)=/RDY, (2)=/TRK0, (1)=/WPRO, (0)=/CHNG.
    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            dsk_prb_prev <= (others => '1');
            dsk_cyl      <= 0;
            dsk_motor    <= '0';
        elsif rising_edge(clk_28m) then
            dsk_prb_prev <= ciab_prb;

            -- /SEL0 activo (1->0): latch de /MTR
            if dsk_prb_prev(3) = '1' and ciab_prb(3) = '0' then
                if dsk_prb_prev(7) = '0' or ciab_prb(7) = '0' then
                    dsk_motor <= '1';
                else
                    dsk_motor <= '0';
                end if;
            end if;

            -- /STEP activo (1->0) con DF0 seleccionada: mueve una pista
            if ciab_prb(3) = '0' and
               dsk_prb_prev(0) = '1' and ciab_prb(0) = '0' then
                if ciab_prb(1) = '0' then          -- /DIR=0: hacia dentro
                    if dsk_cyl < 79 then dsk_cyl <= dsk_cyl + 1; end if;
                else                               -- /DIR=1: hacia fuera
                    if dsk_cyl > 0 then dsk_cyl <= dsk_cyl - 1; end if;
                end if;
            end if;
        end if;
    end process;

    dsk_trk0 <= '0' when dsk_cyl = 0 else '1';

    dsk_stat <= "1111" when ciab_prb(3) = '1' else          -- DF0 no seleccionada
                ('1' & dsk_trk0 & "10") when dsk_motor = '1' else  -- motor on
                (dsk_trk0 & dsk_trk0 & "10");              -- motor off: RDY=TRK0

    -- CIA-A
    inst_ciaa : entity work.Amiga_CIA
        generic map (CLK_HZ => 28_375_000, TOD_HSYNC => false)
        port map (
            clk      => clk_28m,
            reset_n  => system_ready,
            addr     => cpu_addr(11 downto 0),
            data_in  => cpu_data_out(7 downto 0),
            data_out => ciaa_data,
            cs       => sel_ciaa,
            rw       => cpu_rw,
            is_cia_a => '1',
            irq_out  => ciaa_irq,
            dsk_status => cia_dsk_status,
            prb_out  => open,
            dbg_tod  => dbg_tod,
            dbg_timer_running => dbg_timer_run,
            kbd_scancode => kbd_cia_byte,
            kbd_valid    => kbd_cia_valid
        );

    -- CIA-B (byte alto, TOD HSync)
    ciab_wdata <= cpu_data_out(15 downto 8) when cpu_uds = '0' else cpu_data_out(7 downto 0);

    inst_ciab : entity work.Amiga_CIA
        generic map (CLK_HZ => 28_375_000, TOD_HSYNC => true)
        port map (
            clk      => clk_28m,
            reset_n  => system_ready,
            addr     => cpu_addr(11 downto 0),
            data_in  => ciab_wdata,
            data_out => ciab_data,
            cs       => sel_ciab,
            rw       => cpu_rw,
            is_cia_a => '0',
            irq_out  => ciab_irq,
            dsk_status => "1111",   -- CIA-B no usa el estado de la disquetera
            prb_out  => ciab_prb,   -- /SEL0, /MTR, /STEP, /DIR salen al modelo DF0
            dbg_tod  => open,
            dbg_timer_running => open,
            kbd_scancode => (others => '0'),
            kbd_valid    => '0'
        );

    -- Chip RAM 512 KB true dual-port
    inst_ram : entity work.ram_chip
        port map (
            clka  => clk_28m,
            wea   => ram_we,
            addra => ram_addr_mux,
            dina  => ram_dina,
            douta => ram_data,
            clkb  => clk_28m,
            web   => blt_ram_we_w,
            addrb => portb_addr,
            dinb  => blt_ram_data_w,
            doutb => vram_data
        );

    -- CPU
    inst_cpu : entity work.FX68K_Wrapper
        port map (
            CLK      => clk_28m,
            EN_PHI1  => en_phi1,
            EN_PHI2  => en_phi2,
            RESET_IN => system_ready,
            AS_OUT   => cpu_as,
            RW_OUT   => cpu_rw,
            UDS_OUT  => cpu_uds,
            LDS_OUT  => cpu_lds,
            DTACK_IN => cpu_dtack,
            VPA_IN   => cpu_vpa,
            BERR_IN  => '1',
            FC_OUT   => cpu_fc,
            IPL_IN   => cpu_ipl,
            HALT_OUT => cpu_halt,
            ADDR_OUT => cpu_addr,
            DATA_IN  => cpu_data_in,
            DATA_OUT => cpu_data_out
        );

    -- Video / chipset
    inst_denise : entity work.Amiga_Denise
        port map (
            clk_7m      => clk_28m,
            reset_n     => system_ready,
            addr        => chipset_addr,
            data_in     => chipset_data,
            sel_chipset => '1',
            we          => chipset_we2,
            h_cnt       => h_cnt,
            v_cnt       => v_cnt,
            v_pos       => v_pos,
            vram_addr   => vram_addr,
            ddfstrt_dbg => dna_ddfstrt,
            ddfstop_dbg => dna_ddfstop,
            lw_dbg      => dna_lw,
            nz_dbg      => dna_nz,
            col0_dbg    => dna_col0,
            col1_dbg    => dna_col1,
            bplpt_dbg   => dna_pt,
            vram_data   => vram_data,
            red         => denise_r,
            green       => denise_g,
            blue        => denise_b
        );

    inst_blitter : entity work.Amiga_Blitter
        port map (
            clk        => clk_28m,
            reset_n    => system_ready,
            cpu_addr   => cpu_addr(15 downto 0),
            cpu_data   => cpu_data_out,
            cpu_as     => blt_cpu_as,
            cpu_rw     => cpu_rw,
            gnt        => blt_gnt,
            dma_req    => blt_dma_req,
            rd_active  => blt_rd_active,
            ram_addr_r => blt_ram_addr_r,
            ram_data_r => ram_data,
            ram_addr_w => blt_ram_addr_w,
            ram_data_w => blt_ram_data_w,
            ram_we_w   => blt_ram_we_w,
            busy       => blt_busy,
            zero       => blt_zero
        );

    inst_copper : entity work.Amiga_Copper
        port map (
            clk        => clk_28m,
            reset_n    => system_ready,
            gnt        => cop_gnt,
            vblank     => vblank_pulse,
            dma_req    => cop_dma_req,
            dma_enable => cop_dma_enable,
            cpu_addr   => cpu_addr(15 downto 0),
            cpu_data   => cpu_data_out,
            cpu_as     => cop_cpu_as,
            cpu_rw     => cpu_rw,
            v_cnt      => v_pos,
            h_cnt      => h_pos,
            ram_data   => vram_data,
            ram_addr   => cop_ram_addr,
            reg_addr   => cop_reg_addr,
            reg_data   => cop_reg_data,
            reg_we     => cop_reg_we,
            ir1_dbg    => cop_ir1,
            ir2_dbg    => cop_ir2,
            pc_dbg     => cop_pc,
            cop1lc_dbg => cop_lc,
            cop2lc_dbg => cop2lc_v
        );

    video_out_inst : entity work.video_subsystem
        port map (
            pixel_clk  => clk_28m,
            serial_clk => clk_141m,
            reset_n    => pll_locked,
            red_in     => vid_red,
            green_in   => vid_green,
            blue_in    => vid_blue,
            hsync_in   => vid_hsync,
            vsync_in   => vid_vsync,
            blank_in   => vid_blank,
            hdmi_tx_p  => hdmi_tx_p,
            hdmi_tx_n  => hdmi_tx_n
        );

    -- SERDAT ($DFF030)
    serdat_hit <= '1' when chipset_we = '1' and cpu_addr(8 downto 1) = x"18" else '0';

    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            serdat_wr <= '0';
            serdat_byte <= (others => '0');
            serdat_hit_prev <= '0';
        elsif rising_edge(clk_28m) then
            serdat_wr <= '0';
            if serdat_hit = '1' and serdat_hit_prev = '0' then
                serdat_byte <= cpu_data_out(7 downto 0);
                serdat_wr   <= '1';
            end if;
            serdat_hit_prev <= serdat_hit;
        end if;
    end process;

    -- SERDATR ($DFF018): RBF (bit 14) es espejo de INTREQ(11), como en el
    -- Amiga real. Un byte recibido activa INTREQ(11); se desactiva al leer
    -- SERDATR o cuando la CPU escribe INTREQ con el bit 11.
    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            serdatr_data <= (others => '0');
            serdatr_ovrun <= '0';
            serdatr_read_cycle <= '0';
            rd_cnt <= (others => '0');
            ser_rbf_pulse <= '0';
            ser_rbf_clear <= '0';
            serdatr_rd_lat <= (others => '0');
        elsif rising_edge(clk_28m) then
            ser_rbf_pulse <= '0';
            ser_rbf_clear <= '0';
            if cpu_as = '0' and cpu_rw = '1' and
               cpu_addr(23 downto 16) = x"DF" and
               cpu_addr(8 downto 1) = x"0C" then
                serdatr_read_cycle <= '1';
                serdatr_rd_lat <= cpu_data_in;   -- lo que ve realmente la CPU
            elsif cpu_as = '1' and serdatr_read_cycle = '1' then
                serdatr_read_cycle <= '0';
                -- IMPORTANTE: leer SERDATR NO borra RBF en el Amiga real.
                -- Solo se borra escribiendo INTREQ(11)=0. Si lo borrasemos
                -- aqui, un byte que llegue durante el ciclo de lectura se
                -- pierde (DiagROM sondea en bucle y se perdian casi todos).
                rd_cnt <= rd_cnt + 1;
                serdatr_ovrun <= '0';   -- el flag de overrun si se limpia al leer
            end if;
            if ser_rx_valid = '1' then
                -- El byte nuevo siempre se guarda (gana el ultimo); si aun no
                -- se habia leido el anterior, se marca OVRUN.
                if intreq(11) = '1' then
                    serdatr_ovrun <= '1';
                end if;
                serdatr_data  <= ser_rx_data;
                ser_rbf_pulse <= '1';
            end if;
        end if;
    end process;

    serdatr_val <= serdatr_ovrun & intreq(11) & serdat_tbe & serdat_tbe &
                   '1' & '0' & '0' & '1' & serdatr_data;

    -- Traza de bus para comparar con el emulador de referencia.
    -- Durante el volcado, el pin TX pertenece al volcado (no a la UART Amiga).
    uart_tx_out <= trace_tx when trace_active = '1' else
                   flop_uart_tx when loader_active = '1' else
                   amiga_tx;

    inst_trace : entity work.bus_trace
        generic map (
            CLK_HZ => 28_375_000,
            BAUD   => 1_000_000,
            DEPTH  => 16384,
            CYCLES => 28_000_000,
            SKIP   => 56_750_000,
            LOADRAM   => false,
            LOAD_BASE => 0,
            LOAD_WORDS => 262144,
            SELFTEST => false
        )
        port map (
            clk       => clk_28m,
            reset_n   => system_ready,
            addr      => cpu_addr(23 downto 0),
            data_out  => cpu_data_out,
            data_in   => cpu_data_in,
            n_as      => cpu_as,
            rw        => cpu_rw,
            fc        => cpu_fc,
            bus_state => bus_state,
            tx        => trace_tx,
            active    => trace_active,
            dbg_cnt   => trace_cnt,
            dbg_rd    => trace_rd,
            dbg_state => trace_state,
            ram_addr_o => ld_addr,
            ram_data_i => vram_data,
            ld_active  => ld_active
        );

    inst_serdat : entity work.serdat_uart
        generic map (CLK_HZ => 28_375_000, BAUD => 9600, ADDR_BITS => 11)
        port map (
            clk     => clk_28m,
            reset_n => system_ready,
            wr_en   => serdat_wr or echo_wr,
            wr_byte => ser_rx_data when echo_wr = '1' else serdat_byte,
            tbe     => serdat_tbe,
            uart_tx => amiga_tx
        );

    -- Mientras se carga el ADF por UART, el teclado no debe interpretar esos
    -- bytes a 9600 baudios.
    loader_active <= '1' when flop_adf_done = '0' and flop_adf_timeout = '0' else '0';
    kbd_rx_in <= uart_rx_in when loader_active = '0' else '1';

    -- Sin ADF cargado se mantiene el modelo estatico de "sin disco" (el que
    -- hacia aparecer la mano). Con ADF se usa el estado real de paula_floppy.
    cia_dsk_status <= flop_dsk_status when flop_adf_done = '1' else dsk_stat;
    -- DSKBYTR/DSKDATR solo tienen sentido si hay ADF; sin el, 0 como antes.
    flop_read_data <= flop_reg_data_out when flop_adf_done = '1' else x"0000";

    inst_kbd : entity work.keyboard_uart
        generic map (CLK_HZ => 28_375_000, BAUD => 9600)
        port map (
            clk            => clk_28m,
            reset_n        => system_ready,
            rx_in          => kbd_rx_in,
            scancode       => kbd_scancode,
            scancode_valid => kbd_valid,
            rx_byte_out    => ser_rx_data,
            rx_valid_out   => ser_rx_valid
        );

    -- SRAM externa + subsistema de disquetera (ADF + paula_floppy Minimig)
    inst_floppy : entity work.floppy_subsystem
        port map (
            clk          => clk_28m,
            reset_n      => reset_n,
            system_ready => system_ready,
            clk7_en      => en_phi1,
            clk7n_en     => en_phi2,
            sof          => vblank_pulse,
            uart_rx      => uart_rx_in,
            uart_tx      => flop_uart_tx,
            sram_addr    => addr,
            sram_data_a  => data_a,
            sram_data_b  => data_b,
            sram_we_a    => we_a,
            sram_oe_a    => oe_a,
            sram_ce_a    => ce_a,
            sram_we_b    => we_b,
            sram_oe_b    => oe_b,
            sram_ce_b    => ce_b,
            ciab_prb     => ciab_prb,
            dsk_status   => flop_dsk_status,
            reg_addr     => chipset_addr(8 downto 1),
            reg_data_in  => chipset_data,
            reg_we       => chipset_we2,
            reg_data_out => flop_reg_data_out,
            dmacon_dsken => dmacon(4),
            dma_req      => flop_dma_req,
            dma_gnt      => flop_dma_gnt,
            dma_addr     => flop_dma_addr,
            dma_data     => flop_dma_data,
            dma_we       => flop_dma_we,
            blckint      => flop_blckint,
            syncint      => flop_syncint,
            adf_done     => flop_adf_done,
            adf_timeout  => flop_adf_timeout
        );

end rtl;
