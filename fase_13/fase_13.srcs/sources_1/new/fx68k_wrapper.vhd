library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity FX68K_Wrapper is
    Port ( 
        CLK         : in  STD_LOGIC;
        EN_PHI1     : in  STD_LOGIC;
        EN_PHI2     : in  STD_LOGIC;
        RESET_IN    : in  STD_LOGIC;
        
        -- Bus de Control
        AS_OUT      : out STD_LOGIC;
        RW_OUT      : out STD_LOGIC;
        UDS_OUT     : out STD_LOGIC;
        LDS_OUT     : out STD_LOGIC;
        DTACK_IN    : in  STD_LOGIC;
        VPA_IN      : in  STD_LOGIC; -- NUEVO: Para Autovector
        BERR_IN     : in  STD_LOGIC; -- NUEVO: Para Bus Error
        
        -- Estado del Procesador
        FC_OUT      : out STD_LOGIC_VECTOR(2 downto 0); -- NUEVO: Function Codes
        IPL_IN      : in  STD_LOGIC_VECTOR(2 downto 0); -- Interrupciones
        HALT_OUT    : out STD_LOGIC;
        
        -- Datos y Direcciones
        ADDR_OUT    : out STD_LOGIC_VECTOR(31 downto 0);
        DATA_IN     : in  STD_LOGIC_VECTOR(15 downto 0);
        DATA_OUT    : out STD_LOGIC_VECTOR(15 downto 0)
    );
end FX68K_Wrapper;

architecture Behavioral of FX68K_Wrapper is
    signal addr_short : std_logic_vector(23 downto 1);
begin
    ADDR_OUT <= X"00" & addr_short & '0';

    cpu_core : entity work.fx68k
    port map (
        clk      => CLK,
        enPhi1   => EN_PHI1,
        enPhi2   => EN_PHI2,
        HALTn    => '1',
        extReset => not RESET_IN,
        pwrUp    => not RESET_IN,
        
        ASn      => AS_OUT,
        eRWn     => RW_OUT,
        LDSn     => LDS_OUT,
        UDSn     => UDS_OUT,
        DTACKn   => DTACK_IN,
        VPAn     => VPA_IN,  -- Conectado
        BERRn    => BERR_IN, -- Conectado
        
        iEdb     => DATA_IN,
        oEdb     => DATA_OUT,
        eab      => addr_short,
        
        oHALTEDn => HALT_OUT,
        
        -- Conexión de Interrupciones y Estado
        IPL0n    => IPL_IN(0),
        IPL1n    => IPL_IN(1),
        IPL2n    => IPL_IN(2),
        
        FC0      => FC_OUT(0),
        FC1      => FC_OUT(1),
        FC2      => FC_OUT(2),
        
        -- Pines no usados por ahora
        BRn      => '1',
        BGACKn   => '1',
        E        => open,
        VMAn     => open,
        BGn      => open,
        oRESETn  => open
    );
end Behavioral;