---------------------------------------------------
-- Amiga_Blitter.vhd  VERSION 3.0
-- Canales A,B,C,D con LF completa, mascaras First/Last word,
-- modo descendente, modo relleno (IFE/EFE) y MODO LINEA.
--
-- Cambios respecto a la version 2.0 (necesarios para la pantalla
-- "Insert disk" de Kickstart 1.3, que se dibuja con ~270 blits en modo
-- linea + ~850 blits normales/descendentes):
--   * MODO LINEA (BLTCON1 bit0). Antes se ignoraba y un blit de linea se
--     ejecutaba como un blit normal de 2 palabras x longitud, escribiendo
--     basura en memoria. Algoritmo equivalente al de UAE.
--   * Latencia de la BRAM: la Chip RAM tiene 1 ciclo de latencia. Antes se
--     capturaba ram_data_r en el ciclo siguiente a poner la direccion, es
--     decir, el dato de la lectura ANTERIOR. Ahora cada lectura tiene tres
--     pasos: RD_REQ (pone direccion) -> RD_WAIT (la BRAM la registra; el
--     puerto A esta en manos del blitter, salida rd_active) -> RD_GET.
--   * Las mascaras FWM/LWM se aplican ANTES del desplazamiento (como en el
--     hardware real) y el "hold" guarda la palabra enmascarada. El hold no
--     se borra al cambiar de fila (en el Amiga real tampoco).
--   * Modo descendente: desplazamiento a la IZQUIERDA y modulos restados.
--   * Modo relleno inclusivo/exclusivo con FCI.
--   * Escritura de registros por flanco (un solo pulso por ciclo de bus):
--     antes BLTSIZE se re-disparaba en cada ciclo de reloj mientras /AS
--     estaba activo.
--
-- BLTCON0:
--   bits 15:12 = ASHIF (shift A / pixel inicial en modo linea)
--   bit  11    = USE_A
--   bit  10    = USE_B
--   bit   9    = USE_C
--   bit   8    = USE_D
--   bits  7:0  = LF (funcion logica minterm)
--
-- BLTCON1 (modo normal):
--   bits 15:12 = BSHIF (shift B)
--   bit   4    = EFE (exclusive fill)
--   bit   3    = IFE (inclusive fill)
--   bit   2    = FCI (fill carry in)
--   bit   1    = DESC (decrement mode)
--   bit   0    = LINE = 0
-- BLTCON1 (modo linea):
--   bits 15:12 = textura (bit inicial de BLTBDAT)
--   bit   6    = SIGN, bit 4 = SUD, bit 3 = SUL, bit 2 = AUL
--   bit   1    = SING (un solo punto por linea horizontal)
--   bit   0    = LINE = 1
--
-- Registros:
--   DFF040 BLTCON0       DFF042 BLTCON1
--   DFF044 BLTAFWM       DFF046 BLTALWM
--   DFF048 BLTCPTH/L     DFF04C BLTBPTH/L
--   DFF050 BLTAPTH/L     DFF054 BLTDPTH/L
--   DFF058 BLTSIZE (disparo)
--   DFF060 BLTCMOD       DFF062 BLTBMOD
--   DFF064 BLTAMOD       DFF066 BLTDMOD
--   DFF070 BLTCDAT       DFF072 BLTBDAT   DFF074 BLTADAT
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Amiga_Blitter is
    Port (
        clk      : in  STD_LOGIC;
        reset_n  : in  STD_LOGIC;
        cpu_addr : in  STD_LOGIC_VECTOR(15 downto 0);
        cpu_data : in  STD_LOGIC_VECTOR(15 downto 0);
        -- Activo a nivel bajo mientras hay una escritura valida de la CPU a
        -- $DFFxxx (datos estables). Se detecta el flanco internamente.
        cpu_as   : in  STD_LOGIC;
        cpu_rw   : in  STD_LOGIC;
        -- gnt = '1': la CPU no va a necesitar el puerto A en los proximos
        -- ciclos, el blitter puede empezar una lectura.
        gnt      : in  STD_LOGIC;
        dma_req  : out STD_LOGIC;
        -- '1' mientras ram_addr_r debe estar en el puerto A (la BRAM la
        -- registra en este ciclo).
        rd_active  : out STD_LOGIC;
        ram_addr_r : out STD_LOGIC_VECTOR(18 downto 1);
        ram_data_r : in  STD_LOGIC_VECTOR(15 downto 0);
        ram_addr_w : out STD_LOGIC_VECTOR(18 downto 1);
        ram_data_w : out STD_LOGIC_VECTOR(15 downto 0);
        ram_we_w   : out STD_LOGIC_VECTOR(1 downto 0);
        busy     : out STD_LOGIC;
        -- BZERO: todas las palabras producidas en D durante el ultimo blit
        -- fueron cero (DMACONR bit13)
        zero     : out STD_LOGIC
    );
end Amiga_Blitter;

architecture Behavioral of Amiga_Blitter is

    -- Registros de control
    signal bltcon0 : std_logic_vector(15 downto 0) := (others => '0');
    signal bltcon1 : std_logic_vector(15 downto 0) := (others => '0');
    signal bltafwm : std_logic_vector(15 downto 0) := x"FFFF";
    signal bltalwm : std_logic_vector(15 downto 0) := x"FFFF";

    -- Punteros fuente/destino (bytes)
    signal bltapt  : unsigned(23 downto 0) := (others => '0');
    signal bltbpt  : unsigned(23 downto 0) := (others => '0');
    signal bltcpt  : unsigned(23 downto 0) := (others => '0');
    signal bltdpt  : unsigned(23 downto 0) := (others => '0');

    -- Modulos
    signal bltamod : signed(15 downto 0) := (others => '0');
    signal bltbmod : signed(15 downto 0) := (others => '0');
    signal bltcmod : signed(15 downto 0) := (others => '0');
    signal bltdmod : signed(15 downto 0) := (others => '0');

    -- Datos precargados
    signal bltadat : std_logic_vector(15 downto 0) := (others => '0');
    signal bltbdat : std_logic_vector(15 downto 0) := (others => '0');
    signal bltcdat : std_logic_vector(15 downto 0) := (others => '0');

    -- Tamano (0 = maximo: 1024 filas / 64 palabras, sale solo por el wrap)
    signal blt_h   : unsigned(9 downto 0) := (others => '0');
    signal blt_w   : unsigned(5 downto 0) := (others => '0');

    -- Contadores
    signal cur_x   : unsigned(5 downto 0) := (others => '0');
    signal cur_y   : unsigned(9 downto 0) := (others => '0');

    -- Datos de trabajo
    signal a_raw   : std_logic_vector(15 downto 0) := (others => '0');
    signal b_raw   : std_logic_vector(15 downto 0) := (others => '0');
    signal c_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal d_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal a_hold  : std_logic_vector(15 downto 0) := (others => '0');
    signal b_hold  : std_logic_vector(15 downto 0) := (others => '0');
    signal fill_c  : std_logic := '0';

    -- Modo linea
    signal lin_shift : unsigned(3 downto 0) := (others => '0');
    signal lin_sign  : std_logic := '0';
    signal lin_onedot: std_logic := '0';
    signal lin_tex   : std_logic_vector(15 downto 0) := (others => '0');

    -- Escritura de registros por flanco
    signal cpu_as_prev : std_logic := '1';

    -- FSM
    type state_t is (
        IDLE,
        RD_REQ, RD_WAIT, RD_GET,   -- lectura DMA generica (canal rd_ch)
        CALC, WRITE_D, NEXT_WORD,  -- modo normal
        L_CALC, L_WRITE, L_STEP    -- modo linea
    );
    signal state : state_t := IDLE;
    -- canal que se esta leyendo: 0 = C, 1 = B, 2 = A, 3 = C en modo linea
    signal rd_ch : integer range 0 to 3 := 0;

    signal blt_active : std_logic := '0';
    signal blt_zero   : std_logic := '1';

    -- Funcion logica minterm de 8 bits
    function minterm(lf: std_logic_vector(7 downto 0);
                     a, b, c: std_logic) return std_logic is
        variable idx : integer range 0 to 7;
    begin
        idx := 0;
        if a = '1' then idx := idx + 4; end if;
        if b = '1' then idx := idx + 2; end if;
        if c = '1' then idx := idx + 1; end if;
        return lf(idx);
    end function;

    function apply_lf(lf: std_logic_vector(7 downto 0);
                      a, b, c: std_logic_vector(15 downto 0))
                      return std_logic_vector is
        variable result : std_logic_vector(15 downto 0);
    begin
        for i in 0 to 15 loop
            result(i) := minterm(lf, a(i), b(i), c(i));
        end loop;
        return result;
    end function;

    -- Desplazador del blitter.
    --   Ascendente : ((anterior:actual) >> sh) parte baja
    --   Descendente: ((actual:anterior) << sh) parte alta
    function bshift(cur, prev : std_logic_vector(15 downto 0);
                    sh : unsigned(3 downto 0);
                    dsc : std_logic) return std_logic_vector is
        variable t : unsigned(31 downto 0);
    begin
        if dsc = '0' then
            t := shift_right(unsigned(prev & cur), to_integer(sh));
            return std_logic_vector(t(15 downto 0));
        else
            t := shift_left(unsigned(cur & prev), to_integer(sh));
            return std_logic_vector(t(31 downto 16));
        end if;
    end function;

    -- Siguiente canal de lectura en modo normal (orden C, B, A)
    procedure first_channel(signal con0 : in std_logic_vector(15 downto 0);
                            signal st   : out state_t;
                            signal ch   : out integer range 0 to 3) is
    begin
        if con0(9) = '1' then    st <= RD_REQ; ch <= 0;
        elsif con0(10) = '1' then st <= RD_REQ; ch <= 1;
        elsif con0(11) = '1' then st <= RD_REQ; ch <= 2;
        else                      st <= CALC;   ch <= 0;
        end if;
    end procedure;

begin

    busy      <= blt_active;
    dma_req   <= blt_active;
    zero      <= blt_zero;
    rd_active <= '1' when state = RD_WAIT else '0';

    process(clk, reset_n)
        variable wr_pulse : boolean;
        variable a_m, a_s, b_s, d_v : std_logic_vector(15 downto 0);
        variable fc       : std_logic;
        variable ash      : unsigned(3 downto 0);
        variable bsh      : unsigned(3 downto 0);
        variable dsc      : std_logic;
        variable first_w  : boolean;
        variable last_w   : boolean;
        variable pt       : unsigned(23 downto 0);
        variable sh       : unsigned(3 downto 0);
        variable apt_v    : unsigned(23 downto 0);
        variable sgn      : std_logic;
        variable od       : std_logic;
        variable bit_b    : std_logic;
    begin
        if reset_n = '0' then
            bltcon0 <= (others => '0');
            bltcon1 <= (others => '0');
            bltafwm <= x"FFFF";
            bltalwm <= x"FFFF";
            bltapt  <= (others => '0');
            bltbpt  <= (others => '0');
            bltcpt  <= (others => '0');
            bltdpt  <= (others => '0');
            bltamod <= (others => '0');
            bltbmod <= (others => '0');
            bltcmod <= (others => '0');
            bltdmod <= (others => '0');
            bltadat <= (others => '0');
            bltbdat <= (others => '0');
            bltcdat <= (others => '0');
            blt_h   <= (others => '0');
            blt_w   <= (others => '0');
            blt_active <= '0';
            blt_zero   <= '1';
            state   <= IDLE;
            rd_ch   <= 0;
            ram_we_w<= "00";
            cpu_as_prev <= '1';

        elsif rising_edge(clk) then
            ram_we_w <= "00";

            cpu_as_prev <= cpu_as;
            wr_pulse := (cpu_as = '0' and cpu_as_prev = '1' and cpu_rw = '0');

            ash := unsigned(bltcon0(15 downto 12));
            bsh := unsigned(bltcon1(15 downto 12));
            dsc := bltcon1(1);

            -- ============================================================
            -- FSM del Blitter
            -- ============================================================
            if blt_active = '1' then
                case state is

                when IDLE => null;

                -- -------- Lectura DMA (3 ciclos por la latencia de la BRAM)
                when RD_REQ =>
                    if gnt = '1' then
                        case rd_ch is
                            when 0 | 3 => ram_addr_r <= std_logic_vector(bltcpt(18 downto 1));
                            when 1     => ram_addr_r <= std_logic_vector(bltbpt(18 downto 1));
                            when others=> ram_addr_r <= std_logic_vector(bltapt(18 downto 1));
                        end case;
                        state <= RD_WAIT;
                    end if;

                when RD_WAIT =>
                    -- rd_active = '1': la BRAM registra ram_addr_r en este flanco
                    state <= RD_GET;

                when RD_GET =>
                    case rd_ch is
                        when 0 =>
                            c_data  <= ram_data_r;
                            bltcdat <= ram_data_r;
                            if bltcon0(10) = '1' then    rd_ch <= 1; state <= RD_REQ;
                            elsif bltcon0(11) = '1' then rd_ch <= 2; state <= RD_REQ;
                            else state <= CALC; end if;
                        when 1 =>
                            b_raw   <= ram_data_r;
                            bltbdat <= ram_data_r;
                            if bltcon0(11) = '1' then rd_ch <= 2; state <= RD_REQ;
                            else state <= CALC; end if;
                        when 2 =>
                            a_raw   <= ram_data_r;
                            bltadat <= ram_data_r;
                            state <= CALC;
                        when others =>
                            c_data  <= ram_data_r;
                            bltcdat <= ram_data_r;
                            state <= L_CALC;
                    end case;

                -- -------- Modo normal: calculo
                when CALC =>
                    first_w := (cur_x = 0);
                    last_w  := (cur_x = blt_w - 1);

                    -- Canal A: dato (DMA o BLTADAT) -> mascaras -> shifter
                    a_m := a_raw;
                    if bltcon0(11) = '0' then a_m := bltadat; end if;
                    if first_w then a_m := a_m and bltafwm; end if;
                    if last_w  then a_m := a_m and bltalwm; end if;
                    a_s := bshift(a_m, a_hold, ash, dsc);
                    a_hold <= a_m;

                    -- Canal B: si esta activo pasa por el shifter
                    if bltcon0(10) = '1' then
                        b_s := bshift(b_raw, b_hold, bsh, dsc);
                        b_hold <= b_raw;
                    else
                        b_s := bltbdat;
                    end if;

                    if bltcon0(9) = '0' then
                        d_v := apply_lf(bltcon0(7 downto 0), a_s, b_s, bltcdat);
                    else
                        d_v := apply_lf(bltcon0(7 downto 0), a_s, b_s, c_data);
                    end if;

                    -- Relleno (de derecha a izquierda: bit 0 -> bit 15)
                    if bltcon1(3) = '1' or bltcon1(4) = '1' then
                        if first_w then fc := bltcon1(2); else fc := fill_c; end if;
                        for i in 0 to 15 loop
                            if bltcon1(4) = '1' then          -- EFE
                                fc := fc xor d_v(i);
                                d_v(i) := fc;
                            else                               -- IFE
                                if d_v(i) = '1' then
                                    fc := not fc;
                                    d_v(i) := '1';
                                else
                                    d_v(i) := fc;
                                end if;
                            end if;
                        end loop;
                        fill_c <= fc;
                    end if;

                    d_data <= d_v;
                    if d_v /= x"0000" then
                        blt_zero <= '0';
                    end if;

                    if bltcon0(8) = '1' then
                        state <= WRITE_D;
                    else
                        state <= NEXT_WORD;
                    end if;

                -- Escribir canal D (puerto B, respetando al Copper si esta leyendo)
                when WRITE_D =>
                    if gnt = '1' then
                        ram_addr_w <= std_logic_vector(bltdpt(18 downto 1));
                        ram_data_w <= d_data;
                        ram_we_w   <= "11";
                        state <= NEXT_WORD;
                    end if;

                -- Avanzar al siguiente word
                when NEXT_WORD =>
                    if cur_x = blt_w - 1 then
                        -- Fin de fila: +-2 y modulo (restado en descendente)
                        cur_x <= (others => '0');
                        cur_y <= cur_y + 1;
                        if dsc = '0' then
                            if bltcon0(11) = '1' then bltapt <= bltapt + 2 + unsigned(resize(bltamod,24)); end if;
                            if bltcon0(10) = '1' then bltbpt <= bltbpt + 2 + unsigned(resize(bltbmod,24)); end if;
                            if bltcon0(9)  = '1' then bltcpt <= bltcpt + 2 + unsigned(resize(bltcmod,24)); end if;
                            if bltcon0(8)  = '1' then bltdpt <= bltdpt + 2 + unsigned(resize(bltdmod,24)); end if;
                        else
                            if bltcon0(11) = '1' then bltapt <= bltapt - 2 - unsigned(resize(bltamod,24)); end if;
                            if bltcon0(10) = '1' then bltbpt <= bltbpt - 2 - unsigned(resize(bltbmod,24)); end if;
                            if bltcon0(9)  = '1' then bltcpt <= bltcpt - 2 - unsigned(resize(bltcmod,24)); end if;
                            if bltcon0(8)  = '1' then bltdpt <= bltdpt - 2 - unsigned(resize(bltdmod,24)); end if;
                        end if;

                        if cur_y = blt_h - 1 then
                            blt_active <= '0';
                            state      <= IDLE;
                        else
                            first_channel(bltcon0, state, rd_ch);
                        end if;
                    else
                        cur_x <= cur_x + 1;
                        if dsc = '0' then
                            if bltcon0(11) = '1' then bltapt <= bltapt + 2; end if;
                            if bltcon0(10) = '1' then bltbpt <= bltbpt + 2; end if;
                            if bltcon0(9)  = '1' then bltcpt <= bltcpt + 2; end if;
                            if bltcon0(8)  = '1' then bltdpt <= bltdpt + 2; end if;
                        else
                            if bltcon0(11) = '1' then bltapt <= bltapt - 2; end if;
                            if bltcon0(10) = '1' then bltbpt <= bltbpt - 2; end if;
                            if bltcon0(9)  = '1' then bltcpt <= bltcpt - 2; end if;
                            if bltcon0(8)  = '1' then bltdpt <= bltdpt - 2; end if;
                        end if;
                        first_channel(bltcon0, state, rd_ch);
                    end if;

                -- -------- Modo linea: un pixel por iteracion
                when L_CALC =>
                    -- A = BLTADAT (normalmente $8000) enmascarado y desplazado
                    -- hasta el pixel actual
                    a_s := std_logic_vector(shift_right(unsigned(bltadat and bltafwm),
                                                        to_integer(lin_shift)));
                    if bltcon1(1) = '1' and lin_onedot = '1' then
                        a_s := (others => '0');     -- SING: un punto por fila
                    end if;
                    lin_onedot <= '1';
                    if lin_tex(15) = '1' then b_s := x"FFFF"; else b_s := x"0000"; end if;
                    if bltcon0(9) = '1' then
                        d_v := apply_lf(bltcon0(7 downto 0), a_s, b_s, c_data);
                    else
                        d_v := apply_lf(bltcon0(7 downto 0), a_s, b_s, bltcdat);
                    end if;
                    d_data <= d_v;
                    if d_v /= x"0000" then
                        blt_zero <= '0';
                    end if;
                    state <= L_WRITE;

                when L_WRITE =>
                    if bltcon0(8) = '0' then
                        state <= L_STEP;
                    elsif gnt = '1' then
                        -- C y D apuntan a la misma palabra (graphics.library
                        -- carga BLTCPT = BLTDPT)
                        ram_addr_w <= std_logic_vector(bltcpt(18 downto 1));
                        ram_data_w <= d_data;
                        ram_we_w   <= "11";
                        state <= L_STEP;
                    end if;

                when L_STEP =>
                    pt    := bltcpt;
                    sh    := lin_shift;
                    apt_v := bltapt;
                    sgn   := lin_sign;
                    od    := lin_onedot;

                    -- Termino de error (BLTAPT): +BLTBMOD si SIGN, si no +BLTAMOD.
                    -- En modo linea el acumulador de Bresenham opera SOLO sobre los
                    -- 16 bits bajos (BLTAPTL), sin acarreo a BLTAPTH (bits 23:16).
                    if bltcon0(11) = '1' then
                        if sgn = '1' then
                            apt_v(15 downto 0) := apt_v(15 downto 0) + unsigned(bltbmod);
                        else
                            apt_v(15 downto 0) := apt_v(15 downto 0) + unsigned(bltamod);
                        end if;
                    end if;

                    -- Paso menor (solo si SIGN = 0)
                    if sgn = '0' then
                        if bltcon1(4) = '1' then            -- SUD
                            if bltcon1(3) = '1' then        -- SUL: y--
                                pt := pt - unsigned(resize(bltcmod, 24)); od := '0';
                            else                            -- y++
                                pt := pt + unsigned(resize(bltcmod, 24)); od := '0';
                            end if;
                        else
                            if bltcon1(3) = '1' then        -- x--
                                if sh = 0 then sh := x"F"; pt := pt - 2; else sh := sh - 1; end if;
                            else                            -- x++
                                if sh = 15 then sh := x"0"; pt := pt + 2; else sh := sh + 1; end if;
                            end if;
                        end if;
                    end if;

                    -- Paso mayor (siempre)
                    if bltcon1(4) = '1' then                -- SUD: eje mayor = Y
                        if bltcon1(2) = '1' then            -- AUL: x--
                            if sh = 0 then sh := x"F"; pt := pt - 2; else sh := sh - 1; end if;
                        else                                -- x++
                            if sh = 15 then sh := x"0"; pt := pt + 2; else sh := sh + 1; end if;
                        end if;
                    else
                        if bltcon1(2) = '1' then            -- y--
                            pt := pt - unsigned(resize(bltcmod, 24)); od := '0';
                        else                                -- y++
                            pt := pt + unsigned(resize(bltcmod, 24)); od := '0';
                        end if;
                    end if;

                    bltcpt     <= pt;
                    bltdpt     <= pt;
                    bltapt     <= apt_v;
                    lin_shift  <= sh;
                    lin_sign   <= apt_v(15);   -- (int16) BLTAPT < 0
                    lin_onedot <= od;
                    lin_tex    <= lin_tex(14 downto 0) & lin_tex(15);

                    cur_y <= cur_y + 1;
                    if cur_y = blt_h - 1 then
                        blt_active <= '0';
                        state      <= IDLE;
                    elsif bltcon0(9) = '1' then
                        rd_ch <= 3; state <= RD_REQ;
                    else
                        state <= L_CALC;
                    end if;

                when others => state <= IDLE;
                end case;
            end if;

            -- ============================================================
            -- Escritura registros CPU (un solo pulso por ciclo de bus).
            -- Va despues de la FSM para que una escritura tenga prioridad.
            -- ============================================================
            if wr_pulse then
                case cpu_addr(8 downto 1) is
                    when x"20" => bltcon0 <= cpu_data;
                    when x"21" => bltcon1 <= cpu_data;
                    when x"22" => bltafwm <= cpu_data;
                    when x"23" => bltalwm <= cpu_data;
                    when x"24" => bltcpt(23 downto 16) <= unsigned(cpu_data(7 downto 0));
                    when x"25" => bltcpt(15 downto 0)  <= unsigned(cpu_data(15 downto 1) & '0');
                    when x"26" => bltbpt(23 downto 16) <= unsigned(cpu_data(7 downto 0));
                    when x"27" => bltbpt(15 downto 0)  <= unsigned(cpu_data(15 downto 1) & '0');
                    -- BLTAPTL sin forzar el bit 0: en modo linea es el
                    -- termino de error con signo
                    when x"28" => bltapt(23 downto 16) <= unsigned(cpu_data(7 downto 0));
                    when x"29" => bltapt(15 downto 0)  <= unsigned(cpu_data);
                    when x"2A" => bltdpt(23 downto 16) <= unsigned(cpu_data(7 downto 0));
                    when x"2B" => bltdpt(15 downto 0)  <= unsigned(cpu_data(15 downto 1) & '0');
                    -- BLTSIZE: disparo
                    when x"2C" =>
                        blt_h      <= unsigned(cpu_data(15 downto 6));
                        blt_w      <= unsigned(cpu_data(5 downto 0));
                        cur_x      <= (others => '0');
                        cur_y      <= (others => '0');
                        a_hold     <= (others => '0');
                        b_hold     <= (others => '0');
                        a_raw      <= bltadat;
                        b_raw      <= bltbdat;
                        c_data     <= bltcdat;
                        blt_active <= '1';
                        blt_zero   <= '1';      -- BZERO se reevalua en cada blit
                        if bltcon1(0) = '1' then
                            -- Modo linea
                            lin_shift  <= unsigned(bltcon0(15 downto 12));
                            lin_sign   <= bltcon1(6);
                            lin_onedot <= '0';
                            lin_tex    <= std_logic_vector(rotate_left(unsigned(bltbdat),
                                                     to_integer(unsigned(bltcon1(15 downto 12)))));
                            if bltcon0(9) = '1' then
                                rd_ch <= 3; state <= RD_REQ;
                            else
                                state <= L_CALC;
                            end if;
                        else
                            first_channel(bltcon0, state, rd_ch);
                        end if;
                    when x"30" => bltcmod <= signed(cpu_data(15 downto 1) & '0');
                    when x"31" => bltbmod <= signed(cpu_data(15 downto 1) & '0');
                    -- BLTAMOD/BLTBMOD llevan valores impares en modo linea?
                    -- No: son 4*(dy-dx) y 4*dy, siempre pares.
                    when x"32" => bltamod <= signed(cpu_data(15 downto 1) & '0');
                    when x"33" => bltdmod <= signed(cpu_data(15 downto 1) & '0');
                    when x"38" => bltcdat <= cpu_data;
                    when x"39" => bltbdat <= cpu_data;
                    when x"3A" => bltadat <= cpu_data;
                    when others => null;
                end case;
            end if;
        end if;
    end process;

end Behavioral;
