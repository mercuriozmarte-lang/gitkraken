library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bus_controller is
    Port (
        clk          : in  std_logic;
        reset_n      : in  std_logic;
        cpu_addr     : in  std_logic_vector(23 downto 1);
        cpu_wdata    : in  std_logic_vector(15 downto 0);
        cpu_rdata    : out std_logic_vector(15 downto 0);
        cpu_as_n     : in  std_logic;
        cpu_uds_n    : in  std_logic;
        cpu_lds_n    : in  std_logic;
        cpu_rw       : in  std_logic;
        cpu_dtack_n  : out std_logic;
        overlay_in   : in  std_logic;   -- NUEVO: viene del CIA-A PRA bit 0
        rom_data     : in  std_logic_vector(15 downto 0);
        sram_addr    : out std_logic_vector(18 downto 0);
        sram_data_a  : inout std_logic_vector(7 downto 0);
        sram_data_b  : inout std_logic_vector(7 downto 0);
        sram_ce_a_n  : out std_logic;
        sram_ce_b_n  : out std_logic;
        sram_oe_n    : out std_logic;
        sram_we_n    : out std_logic;
        dbg_state    : out std_logic_vector(2 downto 0);
        dbg_rdata    : out std_logic_vector(15 downto 0)
    );
end bus_controller;

architecture rtl of bus_controller is

    type state_t is (S_IDLE, S_ACCESS, S_ACK, S_HOLD, S_RELEASE);
    signal state : state_t := S_IDLE;

    signal is_chip_ram : std_logic;
    signal is_slow_ram : std_logic;
    signal is_rom_hi   : std_logic;

    signal sel_rom     : std_logic;
    signal sel_ram     : std_logic;

    signal wait_cnt : unsigned(3 downto 0);

    signal ce_active  : std_logic;
    signal we_active  : std_logic;
    signal oe_active  : std_logic;
    signal data_drive : std_logic;

    signal lds_lat : std_logic := '1';
    signal uds_lat : std_logic := '1';

    signal rdata_int : std_logic_vector(15 downto 0);

begin

    is_chip_ram <= '1' when cpu_addr(23 downto 19) = "00000" else '0';
    is_slow_ram <= '1' when cpu_addr(23 downto 19) = "11000" else '0';
    is_rom_hi   <= '1' when cpu_addr(23 downto 19) = "11111" else '0';

    -- overlay_in viene del exterior (CIA-A bit 0)
    sel_rom <= '1' when (is_rom_hi = '1') or (is_chip_ram = '1' and overlay_in = '1') else '0';
    sel_ram <= '1' when (is_chip_ram = '1' and overlay_in = '0') or (is_slow_ram = '1') else '0';

    sram_addr(17 downto 0) <= cpu_addr(18 downto 1);
    sram_addr(18)          <= '0' when is_chip_ram = '1' else '1';

    process(clk, reset_n)
    begin
        if reset_n = '0' then
            lds_lat <= '1';
            uds_lat <= '1';
        elsif rising_edge(clk) then
            if state = S_IDLE then
                lds_lat <= '1';
                uds_lat <= '1';
            else
                if cpu_lds_n = '0' then lds_lat <= '0'; end if;
                if cpu_uds_n = '0' then uds_lat <= '0'; end if;
            end if;
        end if;
    end process;

    process(clk, reset_n)
    begin
        if reset_n = '0' then
            state       <= S_IDLE;
            cpu_dtack_n <= '1';
            wait_cnt    <= (others => '0');
        elsif rising_edge(clk) then
            case state is
                when S_IDLE =>
                    cpu_dtack_n <= '1';
                    if cpu_as_n = '0' then
                        wait_cnt <= (others => '0');
                        state    <= S_ACCESS;
                    end if;
                when S_ACCESS =>
                    if wait_cnt = 15 then
                        state <= S_ACK;
                    else
                        wait_cnt <= wait_cnt + 1;
                    end if;
                when S_ACK =>
                    cpu_dtack_n <= '0';
                    if cpu_as_n = '1' then
                        state <= S_HOLD;
                    end if;
                when S_HOLD =>
                    cpu_dtack_n <= '1';
                    state       <= S_RELEASE;
                when S_RELEASE =>
                    cpu_dtack_n <= '1';
                    state       <= S_IDLE;
            end case;
        end if;
    end process;

    ce_active <= '1' when (state = S_ACCESS or state = S_ACK or state = S_HOLD)
                          and sel_ram = '1' else '0';
    we_active <= '1' when (state = S_ACCESS or state = S_ACK)
                          and sel_ram = '1' and cpu_rw = '0' else '0';
    oe_active <= '1' when (state = S_ACCESS or state = S_ACK)
                          and sel_ram = '1' and cpu_rw = '1' else '0';
    data_drive <= '1' when (state = S_ACCESS or state = S_ACK or state = S_HOLD)
                           and sel_ram = '1' and cpu_rw = '0' else '0';

    process(ce_active, we_active, oe_active, lds_lat, uds_lat)
    begin
        sram_ce_a_n <= '1';
        sram_ce_b_n <= '1';
        sram_oe_n   <= '1';
        sram_we_n   <= '1';
        if ce_active = '1' then
            if lds_lat = '0' then sram_ce_a_n <= '0'; end if;
            if uds_lat = '0' then sram_ce_b_n <= '0'; end if;
            if we_active = '1' then
                sram_we_n <= '0';
            elsif oe_active = '1' then
                sram_oe_n <= '0';
            end if;
        end if;
    end process;

    sram_data_a <= cpu_wdata(7 downto 0)  when (data_drive = '1' and lds_lat = '0') else (others => 'Z');
    sram_data_b <= cpu_wdata(15 downto 8) when (data_drive = '1' and uds_lat = '0') else (others => 'Z');

    rdata_int <= rom_data when sel_rom = '1' else
                 (sram_data_b & sram_data_a);
    cpu_rdata <= rdata_int;

    dbg_rdata <= rdata_int;
    dbg_state <= "000" when state = S_IDLE    else
                 "001" when state = S_ACCESS  else
                 "010" when state = S_ACK     else
                 "011" when state = S_HOLD    else
                 "100";

end rtl;