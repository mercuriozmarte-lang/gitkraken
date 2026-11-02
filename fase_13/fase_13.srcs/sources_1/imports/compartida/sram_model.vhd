library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sram_model is
    generic (
        ADDR_BITS : integer := 19;
        NAME      : string  := "SRAM"
    );
    port (
        addr    : in    std_logic_vector(ADDR_BITS-1 downto 0);
        data_io : inout std_logic_vector(7 downto 0);
        ce_n    : in    std_logic;
        oe_n    : in    std_logic;
        we_n    : in    std_logic
    );
end sram_model;

architecture behav of sram_model is
    type mem_t is array (0 to (2**ADDR_BITS)-1) of std_logic_vector(7 downto 0);
    signal mem : mem_t := (others => (others => '0'));
    signal data_out : std_logic_vector(7 downto 0) := (others => '0');

    signal data_captured : std_logic_vector(7 downto 0) := (others => '0');
    signal addr_captured : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
begin

    -- Driver de salida: solo conduce cuando CE=0, OE=0, WE=1
    data_io <= data_out when (ce_n = '0' and oe_n = '0' and we_n = '1')
               else (others => 'Z');

    data_out <= mem(to_integer(unsigned(addr)));

    -- Captura de dirección y datos mientras WE está bajo
    process(we_n, data_io, addr)
    begin
        if we_n = '0' then
            data_captured <= data_io;
            addr_captured <= unsigned(addr);
        end if;
    end process;

    -- Commit en el flanco de subida de WE (como la SRAM real)
    process(we_n)
    begin
        if we_n'event and we_n = '1' then
            if ce_n = '0' then
                mem(to_integer(addr_captured)) <= data_captured;
                report NAME & " WRITE addr=0x" &
                       integer'image(to_integer(addr_captured)) &
                       " data=0x" &
                       integer'image(to_integer(unsigned(data_captured)))
                    severity note;
            end if;
        end if;
    end process;

    -- Traza de lecturas
    process(oe_n)
    begin
        if oe_n'event and oe_n = '0' then
            if ce_n = '0' then
                report NAME & " READ-START addr=0x" &
                       integer'image(to_integer(unsigned(addr)))
                    severity note;
            end if;
        end if;
    end process;

end behav;