-- Send byte units over the one-wire bus

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.one_wire_types.all;

entity one_wire_byte_ops is
	port(
		clock_i         : in  std_logic;
		-- Synchronous reset
		reset_i         : in  std_logic;

		-- Four-phase transaction handshake
		req_i           : in  std_ulogic;
		ack_o           : out std_ulogic;

		-- All control signals must remain valid/unchanged from the assertion of req_i to its deassertion
		operation_i     : in  t_operation;

		data_read_o     : out t_byte_data;
		data_write_i    : in  t_byte_data;
		-- Presence indicator, updated when OPERATION_RESET is issued
		-- High when device was detected
		presence_o      : out std_ulogic;
		
		-- Position of the last bit to write or read
		-- Using this port, sub-byte units can be sent or received
		last_bit_i      : in  t_bit_position := "111";

		-- Ports to connect to one_wire_master
		ow_req_o        : out std_ulogic;
		ow_ack_i        : in  std_ulogic;
		ow_operation_o  : out t_operation;
		ow_data_read_i  : in  std_ulogic;
		ow_data_write_o : out std_ulogic
	);
end entity;

architecture rtl of one_wire_byte_ops is
	type t_state is (
		IDLE,
		IN_RESET,
		IN_DATA_OPERATION,
		WAIT_OW_HANDSHAKE,
		DONE
	);

	signal state : t_state := IDLE;

	signal bit_position : integer range 0 to 7;

begin
	-- Wire operation and data write outputs through directly
	ow_operation_o  <= operation_i;
	ow_data_write_o <= data_write_i(bit_position);

	process(clock_i) is
	begin
		if rising_edge(clock_i) then
			ack_o <= '0';

			if reset_i = '1' then
				state      <= IDLE;
				ow_req_o   <= '0';
				presence_o <= '0';
			else
				case state is
					when IDLE =>
						if req_i = '1' then
							case operation_i is
								when OPERATION_WRITE | OPERATION_READ =>
									state        <= IN_DATA_OPERATION;
									-- Start at LSB
									bit_position <= 0;
								when others =>
									state <= IN_RESET;
							end case;
						end if;
					when IN_RESET =>
						ow_req_o <= '1';
						if ow_ack_i = '1' then
							presence_o <= not ow_data_read_i;
							state      <= WAIT_OW_HANDSHAKE;
						end if;
					when IN_DATA_OPERATION =>
						ow_req_o <= '1';
						if ow_ack_i = '1' then
							if operation_i = OPERATION_READ then
								-- Save data bit
								data_read_o(bit_position) <= ow_data_read_i;
							end if;
							state <= WAIT_OW_HANDSHAKE;
						end if;
					when WAIT_OW_HANDSHAKE =>
						-- End the (sub-)request and wait for one_wire_master to acknowledge it
						ow_req_o <= '0';
						if ow_ack_i = '0' then
							case operation_i is
								when OPERATION_WRITE | OPERATION_READ =>
									-- Continue reading as long as the MSB is not reached
									if bit_position < to_integer(last_bit_i) then
										-- Advance bit position
										bit_position <= bit_position + 1;
										state        <= IN_DATA_OPERATION;
									else
										state <= DONE;
									end if;
								when others => -- OPERATION_RESET
									state <= DONE;
							end case;
						end if;
					when DONE =>
						-- Signal completion, wait for confirmation
						ack_o <= '1';
						if req_i = '0' then
							state <= IDLE;
						end if;
				end case;
			end if;
		end if;
	end process;

end architecture;
