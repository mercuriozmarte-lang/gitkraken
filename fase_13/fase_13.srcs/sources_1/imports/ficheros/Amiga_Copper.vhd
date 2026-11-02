---------------------------------------------------
-- FICHERO: Amiga_Copper.vhd
-- VERSION: 1.1 CORREGIDA
-- CORRECCIONES:
--   [FIX-C1] wait_h_pos corregido: era ir1(14 downto 7)
--            que se solapaba con la posicion V. Correcto es
--            ir1(7 downto 1) segun especificacion Amiga:
--              IR1[15:8] = VP (Vertical Position)
--              IR1[7:1]  = HP (Horizontal Position)
--              IR1[0]    = 1  (tipo WAIT/SKIP)
--   [FIX-C2] Mascara de comparacion IR2 implementada:
--              IR2[15:8] = VM (Vertical Mask)
--              IR2[7:1]  = HM (Horizontal Mask)
--              IR2[0]    = 0=WAIT / 1=SKIP
--            Comparacion correcta:
--              (current_v AND VM) >= (VP AND VM)  &&
--              (current_h AND HM) >= (HP AND HM)
--   [FIX-C3] Instruccion SKIP implementada:
--            Si IR2(0)='1' es SKIP (no WAIT).
--            SKIP salta la siguiente instruccion si el haz
--            ya ha pasado la posicion indicada.
--   [FIX-C4] reg_addr usa ir1(8 downto 1) en lugar de
--            ir1(8 downto 0). El bit 0 de MOVE siempre es 0
--            y no forma parte del indice de registro.
--            reg_addr es ahora STD_LOGIC_VECTOR(8 downto 0)
--            con bit 0 forzado a 0 para mantener
--            compatibilidad con el bus de registros.
--
-- INSTRUCCIONES DEL COPPER (Amiga Hardware Reference Manual):
--   MOVE:  IR1(0)='0' → IR1[8:1]=reg, IR2=dato
--   WAIT:  IR1(0)='1', IR2(0)='0' → esperar posicion raster
--   SKIP:  IR1(0)='1', IR2(0)='1' → saltar si posicion pasada
--   END:   WAIT con IR1=x"FFFF", IR2=x"FFFE"
--
-- INTERFACE DE BUS:
--   cpu_addr[11:0]: offset del registro chipset ($080=COP1LCH)
--   cpu_as=0 + cpu_rw=0: escritura activa
--   gnt: grant del arbitro DMA (1=Copper puede acceder a RAM)
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Amiga_Copper is
    Port (
        clk      : in  STD_LOGIC;
        reset_n  : in  STD_LOGIC;
        gnt      : in  STD_LOGIC;  -- DMA grant del arbitro
        vblank   : in  STD_LOGIC;  -- Pulso VBLANK para reinicio automatico
        -- FIX BUG#6: gate por DMACON.DMAEN AND DMACON.COPEN
        dma_enable : in STD_LOGIC;

        dma_req  : out STD_LOGIC;  -- Solicitud de bus DMA

        -- Bus CPU (escritura de registros COP1LC, COPJMP)
        cpu_addr : in  STD_LOGIC_VECTOR(15 downto 0);
        cpu_data : in  STD_LOGIC_VECTOR(15 downto 0);
        cpu_as   : in  STD_LOGIC;
        cpu_rw   : in  STD_LOGIC;

        -- Posicion actual del haz (desde vga_sync / Agnus)
        v_cnt    : in  INTEGER;
        h_cnt    : in  INTEGER;

        -- Bus de RAM (lectura de copper list)
        ram_data : in  STD_LOGIC_VECTOR(15 downto 0);
        ram_addr : out STD_LOGIC_VECTOR(18 downto 1);

        -- Bus de registros chipset (salida MOVE)
        reg_addr : out STD_LOGIC_VECTOR(8 downto 0); -- [8:1]=indice, [0]=0
        reg_data : out STD_LOGIC_VECTOR(15 downto 0);
        reg_we   : out STD_LOGIC;

        -- [DBG] estado interno para diagnostico
        ir1_dbg  : out STD_LOGIC_VECTOR(15 downto 0);
        ir2_dbg  : out STD_LOGIC_VECTOR(15 downto 0);
        pc_dbg   : out STD_LOGIC_VECTOR(17 downto 0);
        cop1lc_dbg : out STD_LOGIC_VECTOR(31 downto 0);
        cop2lc_dbg : out STD_LOGIC_VECTOR(31 downto 0)
    );
end Amiga_Copper;

architecture Behavioral of Amiga_Copper is

    -- Registros base de las copper lists
    signal cop1lc      : std_logic_vector(31 downto 0) := (others => '0');
    signal cop2lc      : std_logic_vector(31 downto 0) := (others => '0');
    signal cop2lc_valid: std_logic := '0';
    signal vblank_prev : std_logic := '0';

    -- Program Counter del Copper (direccion de palabra, 18 bits = 512 KB)
    signal pc : unsigned(18 downto 1) := (others => '0');

    -- Instruction Registers
    signal ir1 : std_logic_vector(15 downto 0) := (others => '0');
    signal ir2 : std_logic_vector(15 downto 0) := (others => '0');

    -- Posiciones WAIT/SKIP decodificadas de IR1 e IR2
    -- [FIX-C1] HP ahora en bits [7:1] de IR1
    signal wait_vp : unsigned(7 downto 0); -- Vertical Position   IR1[15:8]
    signal wait_hp : unsigned(6 downto 0); -- Horizontal Position IR1[7:1]
    signal wait_vm : unsigned(7 downto 0); -- Vertical Mask       IR2[15:8]
    signal wait_hm : unsigned(6 downto 0); -- Horizontal Mask     IR2[7:1]

    -- Posicion actual del haz (8 bits V, 7 bits H)
    signal cur_v : unsigned(7 downto 0);
    signal cur_h : unsigned(6 downto 0);

    -- Resultado de comparacion con mascara
    signal comparison_met : std_logic;

    type state_t is (
        IDLE,
        FETCH1,       -- Solicitar DMA y presentar direccion IR1
        FETCH2,       -- Esperar concesion (direccion ya en el bus)
        FETCH3,       -- Asentamiento de la BRAM
        FETCH4,       -- Capturar IR1, presentar IR2
        FETCH5,       -- Latencia de la BRAM para IR2
        FETCH6,       -- Capturar IR2, soltar el bus
        DECODE,       -- Leer IR2, decodificar instruccion
        EXECUTE_MOVE, -- Ejecutar MOVE: escribir registro chipset
        WAIT_STATE,   -- Esperar condicion de posicion raster
        SKIP_STATE,   -- Evaluar condicion SKIP (1 ciclo)
        YIELD         -- Ceder bus, volver a FETCH1
    );
    signal state : state_t := IDLE;

begin

    -- ============================================================
    -- Decodificacion de campos WAIT/SKIP (combinacional)
    -- [FIX-C1] HP corregido a bits [7:1]
    -- ============================================================
    wait_vp <= unsigned(ir1(15 downto 8));
    wait_hp <= unsigned(ir1(7  downto 1));  -- [FIX-C1] era ir1(14:7)
    wait_vm <= unsigned(ir2(15 downto 8));  -- [FIX-C2] Mascara vertical
    wait_hm <= unsigned(ir2(7  downto 1));  -- [FIX-C2] Mascara horizontal

    -- Posicion actual del haz en coordenadas Amiga:
    --   v_cnt = linea de barrido (0..311, se usa mod 256 como el hardware)
    --   h_cnt = ciclo de color (0..226); el campo HP de WAIT va en unidades
    --           de 2 ciclos de color, por eso se divide entre 2.
    cur_v <= to_unsigned(v_cnt mod 256, 8);
    cur_h <= to_unsigned(h_cnt / 2, 7);

    -- ============================================================
    -- Comparador con mascara (combinacional)
    -- [FIX-C2] Mascara IR2 aplicada correctamente
    -- Condicion: (cur_v AND VM >= VP AND VM) AND
    --            (cur_h AND HM >= HP AND HM)
    -- En la practica: la comparacion se hace bit a bit
    -- con los bits enmascarados.
    -- ============================================================
    process(cur_v, cur_h, wait_vp, wait_hp, wait_vm, wait_hm)
        variable masked_cur_v  : unsigned(7 downto 0);
        variable masked_wait_v : unsigned(7 downto 0);
        variable masked_cur_h  : unsigned(6 downto 0);
        variable masked_wait_h : unsigned(6 downto 0);
    begin
        masked_cur_v  := cur_v  and wait_vm;
        masked_wait_v := wait_vp and wait_vm;
        masked_cur_h  := cur_h  and wait_hm;
        masked_wait_h := wait_hp and wait_hm;

        comparison_met <= '0';
        if masked_cur_v > masked_wait_v then
            -- Ya pasamos la linea: condicion cumplida
            comparison_met <= '1';
        elsif masked_cur_v = masked_wait_v then
            -- Misma linea: verificar posicion H
            if masked_cur_h >= masked_wait_h then
                comparison_met <= '1';
            end if;
        end if;
    end process;

    -- ============================================================
    -- Maquina de estados del Copper
    -- ============================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            state       <= IDLE;
            cop1lc      <= (others => '0');
            cop2lc      <= (others => '0');
            cop2lc_valid<= '0';
            vblank_prev <= '0';
            dma_req     <= '0';
            reg_we      <= '0';
            reg_addr    <= (others => '0');
            reg_data    <= (others => '0');
            ram_addr    <= (others => '0');
            ir1         <= (others => '0');
            ir2         <= (others => '0');
            pc          <= (others => '0');

        elsif rising_edge(clk) then
            reg_we      <= '0'; -- Default: no escribir registros
            vblank_prev <= vblank;

            -- ------------------------------------------------
            -- ESCRITURA DE REGISTROS DE CONTROL DEL COPPER
            -- COP1LCH ($DFF080): parte alta del puntero
            -- COP1LCL ($DFF082): parte baja del puntero
            -- COPJMP1 ($DFF088): strobe de arranque
            -- Usamos bits [11:0] para ignorar prefijo de bus
            -- ------------------------------------------------
            if cpu_as = '0' and cpu_rw = '0' then
                if cpu_addr(11 downto 0) = x"080" then
                    cop1lc(31 downto 16) <= cpu_data;
                end if;
                if cpu_addr(11 downto 0) = x"082" then
                    cop1lc(15 downto 0) <= cpu_data;
                end if;
                if cpu_addr(11 downto 0) = x"084" then
                    cop2lc(31 downto 16) <= cpu_data;
                end if;
                if cpu_addr(11 downto 0) = x"086" then
                    cop2lc(15 downto 0) <= cpu_data;
                    cop2lc_valid <= '1';
                end if;
            end if;

            -- COPJMP1/COPJMP2 son STROBE: se disparan con cualquier acceso,
            -- incluida la LECTURA (DiagROM hace "move.w $dff088,d0").
            if cpu_as = '0' then
                if cpu_addr(11 downto 0) = x"088" then
                    dma_req <= '0';
                    if unsigned(cop1lc(18 downto 1)) /= 0 then
                        pc    <= unsigned(cop1lc(18 downto 1));
                        state <= FETCH1;
                    else
                        state <= IDLE;
                    end if;
                end if;
                if cpu_addr(11 downto 0) = x"08A" then
                    dma_req <= '0';
                    if unsigned(cop2lc(18 downto 1)) /= 0 then
                        pc    <= unsigned(cop2lc(18 downto 1));
                        state <= FETCH1;
                    else
                        state <= IDLE;
                    end if;
                end if;
            end if;

            -- FIX BUG#6: si el Copper DMA no esta habilitado, forzar IDLE.
            -- Las escrituras CPU a COP1LC/COP2LC/COPJMP siguen permitidas
            -- (bloque de arriba), solo congelamos la FSM.
            if dma_enable = '0' then
                state   <= IDLE;
                dma_req <= '0';
            elsif vblank = '1' and vblank_prev = '0' then
                -- En el Amiga real, el pulso VBLANK reinicia SIEMPRE el Copper
                -- desde COP1LC, independientemente del estado actual (IDLE,
                -- WAIT_STATE, etc.). Antes solo se comprobaba en IDLE, por lo
                -- que si una lista quedaba bloqueada en WAIT_STATE nunca se
                -- recuperaba en los frames siguientes.
                dma_req <= '0';
                if unsigned(cop1lc(18 downto 1)) /= 0 then
                    pc    <= unsigned(cop1lc(18 downto 1));
                    state <= FETCH1;
                else
                    state <= IDLE;
                end if;
            else
            -- ------------------------------------------------
            -- FSM PRINCIPAL
            -- ------------------------------------------------
            case state is

                when IDLE =>
                    dma_req <= '0';

                when FETCH1 =>
                    -- Presentar la direccion de IR1 y pedir el bus DMA.
                    -- La BRAM tiene un ciclo de latencia: el dato de esta
                    -- direccion estara en ram_data al final de FETCH2.
                    dma_req  <= '1';
                    ram_addr <= std_logic_vector(pc);
                    state    <= FETCH2;

                when FETCH2 =>
                    -- Esperar la concesion del bus (la direccion ya esta puesta)
                    if gnt = '1' then
                        state <= FETCH3;
                    end if;

                when FETCH3 =>
                    -- Ciclo de asentamiento (la BRAM ya tiene mem[pc] en su salida)
                    state <= FETCH4;

                when FETCH4 =>
                    -- Capturar IR1 y presentar la direccion de IR2
                    ir1      <= ram_data;
                    ram_addr <= std_logic_vector(pc + 1);
                    state    <= FETCH5;

                when FETCH5 =>
                    -- Ciclo de latencia de la BRAM para IR2
                    state <= FETCH6;

                when FETCH6 =>
                    -- Capturar IR2 y soltar el bus
                    ir2     <= ram_data;
                    pc      <= pc + 2;
                    dma_req <= '0';
                    state   <= DECODE;

                when DECODE =>
                    -- ir1/ir2 validos: decidir tipo de instruccion
                    if ir1(0) = '0' then
                        -- MOVE: bit0 de IR1 = 0
                        state <= EXECUTE_MOVE;
                    else
                        -- WAIT o SKIP: IR1=0xFFFF es el final de la lista
                        if ir1 = x"FFFF" then
                            state <= IDLE;
                        elsif ir2(0) = '1' then
                            state <= SKIP_STATE;
                        else
                            state <= WAIT_STATE;
                        end if;
                    end if;

                when EXECUTE_MOVE =>
                    -- [FIX-C4] reg_addr usa ir1[8:1], bit0 forzado a 0
                    -- El indice de registro son los bits [8:1] de IR1
                    -- (direccion word del registro chipset, offset desde $DFF000)
                    reg_addr <= ir1(8 downto 1) & '0';
                    reg_data <= ir2;

                    -- [FIX-COPPER-JMP] Si el MOVE escribe COPJMP1 ($088) o
                    -- COPJMP2 ($08A), el propio Copper salta a la lista
                    -- correspondiente. Si el puntero aun es 0 (durante el
                    -- arranque de Kickstart antes de que LoadView cargue
                    -- GfxBase->LOFlist), pasamos a IDLE en vez de saltar a $0.
                    if ir1(8 downto 1) = "01000100" then        -- $088 COPJMP1
                        reg_we <= '0';
                        if unsigned(cop1lc(18 downto 1)) /= 0 then
                            pc    <= unsigned(cop1lc(18 downto 1));
                            state <= FETCH1;
                        else
                            state <= IDLE;
                        end if;
                    elsif ir1(8 downto 1) = "01000101" then     -- $08A COPJMP2
                        reg_we <= '0';
                        if unsigned(cop2lc(18 downto 1)) /= 0 then
                            pc    <= unsigned(cop2lc(18 downto 1));
                            state <= FETCH1;
                        else
                            state <= IDLE;
                        end if;
                    else
                        -- Con CDANG=0 (valor por defecto OCS), el Copper solo
                        -- puede escribir en registros >= $DFF080 (indice >= $40).
                        if unsigned(ir1(8 downto 1)) >= x"40" then
                            reg_we <= '1';
                        end if;
                        state <= YIELD;
                    end if;

                when WAIT_STATE =>
                    -- Esperar hasta que el haz llegue a la posicion indicada
                    dma_req <= '0';
                    if comparison_met = '1' then
                        state <= YIELD;
                    end if;

                when SKIP_STATE =>
                    -- [FIX-C3] SKIP: si el haz ya paso la posicion,
                    -- saltar la siguiente instruccion (avanzar pc 2 palabras)
                    dma_req <= '0';
                    if comparison_met = '1' then
                        -- Saltamos la siguiente instruccion (2 palabras)
                        pc <= pc + 2;
                    end if;
                    state <= YIELD;

                when YIELD =>
                    -- Ceder el bus un ciclo antes del siguiente fetch
                    dma_req <= '0';
                    state   <= FETCH1;

            end case;
            end if;  -- dma_enable
        end if;
    end process;

    ir1_dbg <= ir1;
    ir2_dbg <= ir2;
    pc_dbg    <= std_logic_vector(pc);   -- direccion de palabra (18 bits)
    cop1lc_dbg <= cop1lc;
    cop2lc_dbg <= cop2lc;

end Behavioral;
