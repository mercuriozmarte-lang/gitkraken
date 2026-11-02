---------------------------------------------------
-- FICHERO COMPLETO: Amiga_Denise.vhd
-- RESOLUCION: Decodificación directa a 0x01XX
---------------------------------------------------

-- ==========================================================
-- [BLOQUE 1: LIBRERIAS Y ENTIDAD]
-- ==========================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Amiga_Denise is
    Port ( 
        clk_7m      : in  STD_LOGIC;
        reset_n     : in  STD_LOGIC;
        addr        : in  STD_LOGIC_VECTOR(15 downto 0);
        data_in     : in  STD_LOGIC_VECTOR(15 downto 0);
        sel_chipset : in  STD_LOGIC;
        we          : in  STD_LOGIC;
        h_cnt       : in  INTEGER;
        v_cnt       : in  INTEGER;
        v_pos       : in  INTEGER;   -- linea de barrido Amiga (0..311)
        vram_addr   : out STD_LOGIC_VECTOR(17 downto 0);
        vram_data   : in  STD_LOGIC_VECTOR(15 downto 0);
        ddfstrt_dbg : out STD_LOGIC_VECTOR(7 downto 0);
        ddfstop_dbg : out STD_LOGIC_VECTOR(7 downto 0);
        lw_dbg      : out STD_LOGIC_VECTOR(7 downto 0);
        nz_dbg      : out STD_LOGIC_VECTOR(15 downto 0);
        col0_dbg    : out STD_LOGIC_VECTOR(11 downto 0);
        col1_dbg    : out STD_LOGIC_VECTOR(11 downto 0);
        bplpt_dbg   : out STD_LOGIC_VECTOR(15 downto 0);
        red         : out STD_LOGIC_VECTOR(7 downto 0);
        green       : out STD_LOGIC_VECTOR(7 downto 0);
        blue        : out STD_LOGIC_VECTOR(7 downto 0)
    );
end Amiga_Denise;

architecture Behavioral of Amiga_Denise is

-- ==========================================================
-- [BLOQUE 2: SEÑALES INTERNAS Y REGISTROS]
-- ==========================================================
    signal bpl1pth : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl1ptl : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl2pth : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl2ptl : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl3pth : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl3ptl : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl4pth : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl4ptl : std_logic_vector(15 downto 0) := (others => '0');

    signal bplcon0 : std_logic_vector(15 downto 0) := (others => '0');
    signal diwstrt : std_logic_vector(15 downto 0) := (others => '0');
    signal diwstop : std_logic_vector(15 downto 0) := (others => '0');
    signal line_words_s : integer range 0 to 80 := 0;
    signal ddfstrt : integer range 0 to 255 := 60;
    signal ddfstop : integer range 0 to 255 := 212;

    type palette_t is array (0 to 15) of std_logic_vector(11 downto 0);
    signal palette_ram : palette_t := (others => x"000");

    -- Punteros de bitplane en direcciones de PALABRA (18 bits = 512 KB)
    signal fp1 : unsigned(17 downto 0) := (others => '0');
    signal fp2 : unsigned(17 downto 0) := (others => '0');
    signal fp3 : unsigned(17 downto 0) := (others => '0');
    signal fp4 : unsigned(17 downto 0) := (others => '0');

    signal next1 : std_logic_vector(15 downto 0) := (others => '0');
    signal next2 : std_logic_vector(15 downto 0) := (others => '0');
    signal next3 : std_logic_vector(15 downto 0) := (others => '0');
    signal next4 : std_logic_vector(15 downto 0) := (others => '0');
    
    signal sh1 : std_logic_vector(15 downto 0) := (others => '0');
    signal sh2 : std_logic_vector(15 downto 0) := (others => '0');
    signal sh3 : std_logic_vector(15 downto 0) := (others => '0');
    signal sh4 : std_logic_vector(15 downto 0) := (others => '0');

    signal tick_cnt  : unsigned(1 downto 0) := "00";
    signal ena_pixel : std_logic := '0';

    signal fetch_phase  : integer range 0 to 6 := 0;
    signal pix_in_block : integer range 0 to 15 := 0;
    -- Nuevo pipeline: un tick por pixel Amiga (HIRES 1/clk, LORES 1/2 clk)
    signal px_cnt  : integer range 0 to 15 := 0;
    signal half_ph : std_logic := '0';
    signal blk_cnt : integer range 0 to 63 := 0;
    signal nz_cnt  : unsigned(15 downto 0) := (others => '0');

    -- Punteros de bitplane "vivos" (como los de Agnus), en direcciones de
    -- PALABRA. Se cargan al escribir BPLxPTH/L y avanzan al final de cada
    -- linea en la que hay DMA de bitplanes (planos > 0 y dentro de la
    -- ventana vertical): + palabras de la linea + modulo.
    -- Antes la fila se calculaba como (v_pos - VSTART); Kickstart 1.3 usa
    -- VSTART=5 pero activa los planos en la linea 44 (por Copper), asi que
    -- la imagen salia desplazada 39 lineas.
    signal cur1 : unsigned(17 downto 0) := (others => '0');
    signal cur2 : unsigned(17 downto 0) := (others => '0');
    signal cur3 : unsigned(17 downto 0) := (others => '0');
    signal cur4 : unsigned(17 downto 0) := (others => '0');
    signal bpl1mod : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl2mod : std_logic_vector(15 downto 0) := (others => '0');

begin

-- ==========================================================
-- [BLOQUE 3: ESCRITURA DE REGISTROS CHIPSET]
-- ==========================================================
    process(clk_7m)
        variable color_idx : integer range 0 to 15;
    begin
        if rising_edge(clk_7m) then
            if sel_chipset = '1' and we = '1' then
                
                -- [FIX-DENISE-1] Direcciones CORRECTAS de los registros BPLxPT
                -- Las anteriores ($88-$8F) eran $DFF110-$DFF11E (BPLxDAT),
                -- no los punteros. Los punteros estan en $DFF0E0-$DFF0EE.
                --   $DFF0E0 BPL1PTH -> addr(8:1) = $70
                --   $DFF0E2 BPL1PTL -> addr(8:1) = $71
                --   $DFF0E4 BPL2PTH -> addr(8:1) = $72
                --   ...
                --   $DFF0EE BPL4PTL -> addr(8:1) = $77
                -- addr(8:1) para BPLCON0: $100>>1 = $80 (esto sigue OK)
                -- addr(8:1) para COLOR00: $180>>1 = $C0
                case addr(8 downto 1) is
                    when x"80" =>  -- BPLCON0 ($DFF100)
                        bplcon0 <= data_in;
                    when x"47" =>  -- DIWSTRT ($DFF08E)
                        diwstrt <= data_in;
                    when x"48" =>  -- DIWSTOP ($DFF090)
                        diwstop <= data_in;
                    when x"49" =>  -- DDFSTRT ($DFF092)
                        ddfstrt <= to_integer(unsigned(data_in(7 downto 0)));
                    when x"4a" =>  -- DDFSTOP ($DFF094)
                        ddfstop <= to_integer(unsigned(data_in(7 downto 0)));
                    when x"84" =>  -- BPL1MOD ($DFF108)
                        bpl1mod <= data_in;
                    when x"85" =>  -- BPL2MOD ($DFF10A)
                        bpl2mod <= data_in;
                    when x"70" =>  -- BPL1PTH ($DFF0E0)
                        bpl1pth <= data_in;
                    when x"71" =>  -- BPL1PTL ($DFF0E2)
                        bpl1ptl <= data_in;
                    when x"72" =>  -- BPL2PTH ($DFF0E4)
                        bpl2pth <= data_in;
                    when x"73" =>  -- BPL2PTL ($DFF0E6)
                        bpl2ptl <= data_in;
                    when x"74" =>  -- BPL3PTH ($DFF0E8)
                        bpl3pth <= data_in;
                    when x"75" =>  -- BPL3PTL ($DFF0EA)
                        bpl3ptl <= data_in;
                    when x"76" =>  -- BPL4PTH ($DFF0EC)
                        bpl4pth <= data_in;
                    when x"77" =>  -- BPL4PTL ($DFF0EE)
                        bpl4ptl <= data_in;
                    when others =>
                        -- COLOR00-COLOR15: $DFF180-$DFF19E -> addr(8:1) = $C0-$CF
                        if addr(8 downto 5) = "1100" then
                            color_idx := to_integer(unsigned(addr(4 downto 1)));
                            palette_ram(color_idx) <= data_in(11 downto 0);
                        end if;
                end case;
            end if;
        end if;
    end process;

-- ==========================================================
-- [BLOQUE 4: GENERADOR DE ENABLE DE PÍXEL]
-- ==========================================================
    ddfstrt_dbg <= std_logic_vector(to_unsigned(ddfstrt, 8));
    ddfstop_dbg <= std_logic_vector(to_unsigned(ddfstop, 8));
    lw_dbg      <= std_logic_vector(to_unsigned(line_words_s, 8));
    nz_dbg      <= std_logic_vector(nz_cnt);
    col0_dbg    <= palette_ram(0);
    col1_dbg    <= palette_ram(1);
    bplpt_dbg   <= bpl1ptl;   -- parte baja del puntero de bitplane 1

    process(clk_7m)
    begin
        if rising_edge(clk_7m) then
            tick_cnt <= tick_cnt + 1;
            if tick_cnt = "11" then
                ena_pixel <= '1';
            else
                ena_pixel <= '0';
            end if;
        end if;
    end process;

-- ==========================================================
-- [BLOQUE 5: PIPELINE DE FETCH Y SALIDA]
-- ==========================================================
    process(clk_7m)
        variable pv : std_logic_vector(3 downto 0);
        variable co : std_logic_vector(11 downto 0);
        variable planes_enabled : integer range 0 to 4;
        variable vfp1 : unsigned(18 downto 0);
        variable vfp2 : unsigned(18 downto 0);
        variable vfp3 : unsigned(18 downto 0);
        variable vfp4 : unsigned(18 downto 0);
        variable line_words : integer range 0 to 80;
        variable bit_tick   : std_logic;
        variable v_start    : integer;
        variable v_stop     : integer;
        variable row        : integer;
    begin
        if rising_edge(clk_7m) then
            if reset_n = '0' then
                fp1 <= (others => '0');
                fp2 <= (others => '0');
                fp3 <= (others => '0');
                fp4 <= (others => '0');
                sh1 <= (others => '0');
                sh2 <= (others => '0');
                sh3 <= (others => '0');
                sh4 <= (others => '0');
                next1 <= (others => '0');
                next2 <= (others => '0');
                next3 <= (others => '0');
                next4 <= (others => '0');
                fetch_phase <= 0;
                pix_in_block <= 0;
                px_cnt  <= 0;
                half_ph <= '0';
                red   <= (others => '0');
                green <= (others => '0');
                blue  <= (others => '0');
                vram_addr <= (others => '0');

            else
                -- ============================================================
                -- Un "tick" por pixel Amiga: HIRES = cada ciclo de reloj,
                -- LORES = cada 2 ciclos (duplicacion de pixel horizontal).
                -- ============================================================
                planes_enabled := to_integer(unsigned(bplcon0(14 downto 12)));
                if planes_enabled > 4 then
                    planes_enabled := 4;
                end if;

                -- Cuenta palabras de bitplane distintas de cero: si crece, el
                -- bitmap tiene contenido y el problema estaria en direcciones.
                if bit_tick = '1' and px_cnt >= 2 and px_cnt <= 8 and
                   (px_cnt mod 2) = 0 and vram_data /= x"0000" then
                    nz_cnt <= nz_cnt + 1;
                end if;

                -- DIWSTRT/DIWSTOP en formato Amiga: la linea de parada lleva
                -- el bit 8 en el bit 7 del byte horizontal (PAL: 0x2C -> 300).
                if diwstrt = x"0000" then
                    v_start := 0;
                    v_stop  := 311;
                else
                    v_start := to_integer(unsigned(diwstrt(15 downto 8)));
                    v_stop  := to_integer(unsigned(diwstop(15 downto 8)));
                    -- Regla del Amiga: si VSTOP < 128 la linea real es
                    -- VSTOP + 256 (permite ventanas PAL que acaban en 300).
                    if v_stop < 128 then
                        v_stop := v_stop + 256;
                    end if;
                end if;

                -- Ancho del fetch segun DDFSTRT/DDFSTOP (lo que realmente
                -- pide el programa): palabras = (DDFSTOP-DDFSTRT)/8 + 1.
                if ddfstop > ddfstrt then
                    line_words := ((ddfstop - ddfstrt) / 8) + 1;
                else
                    line_words := 20;
                end if;
                if line_words > 40 then
                    line_words := 40;
                end if;
                if line_words < 8 then
                    line_words := 20;
                end if;
                line_words_s <= line_words;

                -- Punteros vivos de bitplane (ver declaracion de cur1..cur4).
                -- 1) Fin de una linea con DMA de bitplanes: avanzar la linea
                --    leida + modulo (BPL1MOD planos impares, BPL2MOD pares).
                if h_cnt = 650 and v_pos >= v_start and v_pos <= v_stop then
                    if planes_enabled >= 1 then
                        cur1 <= cur1 + to_unsigned(line_words, 18) +
                                unsigned(resize(signed(bpl1mod(15 downto 1)), 18));
                    end if;
                    if planes_enabled >= 2 then
                        cur2 <= cur2 + to_unsigned(line_words, 18) +
                                unsigned(resize(signed(bpl2mod(15 downto 1)), 18));
                    end if;
                    if planes_enabled >= 3 then
                        cur3 <= cur3 + to_unsigned(line_words, 18) +
                                unsigned(resize(signed(bpl1mod(15 downto 1)), 18));
                    end if;
                    if planes_enabled >= 4 then
                        cur4 <= cur4 + to_unsigned(line_words, 18) +
                                unsigned(resize(signed(bpl2mod(15 downto 1)), 18));
                    end if;
                end if;
                -- 2) Escritura de BPLxPTH/BPLxPTL (CPU o Copper): recarga.
                --    Va despues del avance para que la escritura tenga prioridad.
                if sel_chipset = '1' and we = '1' then
                    case addr(8 downto 1) is
                        when x"70" => cur1(17 downto 15) <= unsigned(data_in(2 downto 0));
                        when x"71" => cur1(14 downto 0)  <= unsigned(data_in(15 downto 1));
                        when x"72" => cur2(17 downto 15) <= unsigned(data_in(2 downto 0));
                        when x"73" => cur2(14 downto 0)  <= unsigned(data_in(15 downto 1));
                        when x"74" => cur3(17 downto 15) <= unsigned(data_in(2 downto 0));
                        when x"75" => cur3(14 downto 0)  <= unsigned(data_in(15 downto 1));
                        when x"76" => cur4(17 downto 15) <= unsigned(data_in(2 downto 0));
                        when x"77" => cur4(14 downto 0)  <= unsigned(data_in(15 downto 1));
                        when others => null;
                    end case;
                end if;

                -- Si el fetch cabe en 640 px se duplica el pixel (LORES).
                if line_words * 16 >= 640 then
                    bit_tick := '1';
                else
                    if half_ph = '1' then
                        half_ph  <= '0';
                        bit_tick := '1';
                    else
                        half_ph  <= '1';
                        bit_tick := '0';
                    end if;
                end if;

                if h_cnt = 0 then
                    -- Inicio de linea: se parte del puntero vivo de cada plano
                    fp1 <= cur1;
                    fp2 <= cur2;
                    fp3 <= cur3;
                    fp4 <= cur4;

                    vram_addr <= std_logic_vector(cur1);

                    px_cnt  <= 0;
                    half_ph <= '0';
                    blk_cnt <= 0;
                    sh1 <= (others => '0');
                    sh2 <= (others => '0');
                    sh3 <= (others => '0');
                    sh4 <= (others => '0');

                elsif bit_tick = '1' then
                    if px_cnt = 15 then
                        -- Fin de bloque de 16 pixeles: cargar el siguiente
                        px_cnt <= 0;
                        blk_cnt <= blk_cnt + 1;
                        sh1 <= next1;
                        sh2 <= next2;
                        sh3 <= next3;
                        sh4 <= next4;
                        fp1 <= fp1 + 1;
                        fp2 <= fp2 + 1;
                        fp3 <= fp3 + 1;
                        fp4 <= fp4 + 1;
                    else
                        px_cnt <= px_cnt + 1;

                        -- Desplazar: el pixel que se muestra es sh(15)
                        sh1 <= sh1(14 downto 0) & '0';
                        sh2 <= sh2(14 downto 0) & '0';
                        sh3 <= sh3(14 downto 0) & '0';
                        sh4 <= sh4(14 downto 0) & '0';

                        -- Pipeline: una palabra de cada plano por bloque
                        case px_cnt is
                            when 1 => vram_addr <= std_logic_vector(fp1);
                            when 2 => next1 <= vram_data;
                            when 3 => vram_addr <= std_logic_vector(fp2);
                            when 4 => next2 <= vram_data;
                            when 5 => vram_addr <= std_logic_vector(fp3);
                            when 6 => next3 <= vram_data;
                            when 7 => vram_addr <= std_logic_vector(fp4);
                            when 8 => next4 <= vram_data;
                            when others => null;
                        end case;
                    end if;
                end if;

                -- Salida de pixel
                if h_cnt < 640 and v_pos >= v_start and v_pos <= v_stop and
                   blk_cnt < line_words then
                    pv := "0000";
                    if planes_enabled >= 1 then pv(0) := sh1(15); end if;
                    if planes_enabled >= 2 then pv(1) := sh2(15); end if;
                    if planes_enabled >= 3 then pv(2) := sh3(15); end if;
                    if planes_enabled >= 4 then pv(3) := sh4(15); end if;

                    co := palette_ram(to_integer(unsigned(pv)));

                    red   <= co(11 downto 8) & co(11 downto 8);
                    green <= co(7 downto 4)  & co(7 downto 4);
                    blue  <= co(3 downto 0)  & co(3 downto 0);
                else
                    red   <= (others => '0');
                    green <= (others => '0');
                    blue  <= (others => '0');
                end if;

            end if;
        end if;
    end process;

end Behavioral;