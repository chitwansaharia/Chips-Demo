library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package one_wire_types is
	subtype t_operation is std_ulogic_vector(1 downto 0);
	constant OPERATION_READ  : t_operation := "00";
	constant OPERATION_WRITE : t_operation := "01";
	constant OPERATION_RESET : t_operation := "11";
	
	subtype t_byte_data is std_ulogic_vector(7 downto 0);
	
	subtype t_bit_position is unsigned(2 downto 0);
end package;
