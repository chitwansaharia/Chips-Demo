library ieee;
use ieee.std_logic_1164.all;

entity clock_divider is
	generic(
		DIVIDE_FACTOR : positive
	);
	port(
		clock_i        : in  std_ulogic;
		reset_i        : in  std_ulogic;
		clock_enable_o : out std_ulogic
	);
end entity;

architecture rtl of clock_divider is
	signal count : integer range 0 to DIVIDE_FACTOR := 0;
begin
	process(clock_i) is
	begin
		if rising_edge(clock_i) then
			clock_enable_o <= '0';

			if reset_i = '1' then
				count <= 0;
			else
				if count < DIVIDE_FACTOR - 1 then
					count <= count + 1;
				else
					count          <= 0;
					clock_enable_o <= '1';
				end if;
			end if;
		end if;
	end process;

end architecture;
