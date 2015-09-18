-- Use the one-wire bus to read a MAC address from a MAXIM DS2502-E48 IC

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.one_wire_types.all;

library ethernet_mac;
use ethernet_mac.crc.all;
use ethernet_mac.utility.all;
use ethernet_mac.ethernet_types.all;

entity one_wire_ds2502_e48 is
	port(
		clock_i             : in  std_ulogic;
		-- Synchronous reset
		reset_i             : in  std_ulogic;

		debug_fifo_we_o     : out std_ulogic;
		debug_fifo_data_o   : out std_ulogic_vector(7 downto 0);

		mac_address_o       : out t_mac_address;
		mac_address_ready_o : out std_ulogic;

		-- Ports to connect to one_wire_byte_ops
		ow_req_o            : out std_ulogic;
		ow_ack_i            : in  std_ulogic;
		ow_operation_o      : out t_operation;
		ow_data_read_i      : in  t_byte_data;
		ow_data_write_o     : out t_byte_data;
		ow_presence_i       : in  std_ulogic;
		ow_last_bit_o       : out t_bit_position
	);
end entity;

architecture rtl of one_wire_ds2502_e48 is
	constant COMMAND_DS2502_SKIP_ROM    : t_byte_data := x"CC";
	constant COMMAND_DS2502_SEARCH_ROM  : t_byte_data := x"F0";
	constant COMMAND_DS2502_READ_MEMORY : t_byte_data := x"F0";
	constant FAMILY_CODE_DS2502_E48     : t_byte_data := x"89";

	constant READ_ADDRESS : std_ulogic_vector(15 downto 0) := (others => '0');

	constant NODE_ADDRESS_BLOCK_LENGTH : integer := 10;

	constant CRC8_POLYNOMIAL : std_ulogic_vector(8 downto 0) := (
		8 | 5 | 4 | 0 => '1',
		others => '0'
	);
	constant CRC8_INIT : std_ulogic_vector(7 downto 0) := x"00";

	constant CRC16_POLYNOMIAL : std_ulogic_vector(16 downto 0) := (
		16 | 15 | 2 | 0 => '1',
		others => '0'
	);
	constant CRC16_POSTINVERT_MAGIC : std_ulogic_vector(15 downto 0) := x"B001";

	-- The CRC8 of the read memory command and address can be calculated at synthesization time
	-- as it is not dependent on any data from the DS2502 IC.
	-- Make sure to update this value when changing the command etc.
	constant READ_MEMORY_CRC8 : std_ulogic_vector(7 downto 0) := reverse_vector(update_crc(update_crc(CRC8_INIT, COMMAND_DS2502_READ_MEMORY, CRC8_POLYNOMIAL), READ_ADDRESS, CRC8_POLYNOMIAL));

	type t_state is (
		RESET_IC,
		TX_SEARCH_ROM,
		RX_ROM_FAMILY_BIT,
		TX_ROM_FAMILY_BIT,
		RX_ROM_BIT,
		TX_ROM_BIT,
		TX_READ_MEMORY,
		TX_MEMORY_ADDRESS_LO,
		TX_MEMORY_ADDRESS_HI,
		RX_COMMAND_CRC,
		RX_DATA,
		VERIFY_CRC,
		WAIT_ACK_LOW,
		DONE
	);

	signal state            : t_state := RESET_IC;
	signal after_wait_state : t_state;

	signal received_bytes : integer range 0 to 40;
	signal rom_search_bit : integer range 0 to 63;

	signal udp_crc : std_ulogic_vector(15 downto 0);

	signal mac_address : t_mac_address;

begin
	mac_address_o <= mac_address;

	process(clock_i)
		procedure write_data(data : in std_ulogic_vector) is
		begin
			ow_operation_o                      <= OPERATION_WRITE;
			ow_data_write_o(data'high downto 0) <= data;
			ow_last_bit_o                       <= to_unsigned(data'high, ow_last_bit_o'length);
			ow_req_o                            <= '1';
		end procedure;

		procedure read_data(last_bit : in t_bit_position := "111") is
		begin
			ow_operation_o <= OPERATION_READ;
			ow_last_bit_o  <= last_bit;
			ow_req_o       <= '1';
		end procedure;

		variable new_mac_address : t_mac_address;

	begin
		if rising_edge(clock_i) then
			debug_fifo_we_o <= '0';

			if reset_i = '1' then
				state               <= RESET_IC;
				ow_req_o            <= '0';
				mac_address_ready_o <= '0';
			else
				-- Go into handshake wait state every time an operation was completed
				if ow_ack_i = '1' then
					state <= WAIT_ACK_LOW;
				end if;

				case state is
					when RESET_IC =>
						ow_operation_o   <= OPERATION_RESET;
						ow_req_o         <= '1';
						after_wait_state <= TX_SEARCH_ROM;
						-- Check IC presence
						if ow_ack_i = '1' and ow_presence_i /= '1' then
							debug_fifo_we_o   <= '1';
							debug_fifo_data_o <= x"34";
							-- Try again
							after_wait_state  <= RESET_IC;
						end if;
					when TX_SEARCH_ROM =>
						-- Search for the correct device on the bus
						write_data(COMMAND_DS2502_SEARCH_ROM);
						--write_data(x"33");
						--after_wait_state <= RX_DATA;
						after_wait_state <= RX_ROM_FAMILY_BIT;
						rom_search_bit   <= 0;
					when RX_ROM_FAMILY_BIT =>
						-- Read two bits: ROM address and complement
						read_data("001");
						after_wait_state <= TX_ROM_FAMILY_BIT;
						if ow_ack_i = '1' then
							debug_fifo_we_o   <= '1';
							debug_fifo_data_o <= ow_data_read_i;
						end if;
					when TX_ROM_FAMILY_BIT =>
						-- Just write out the DS2502-E48 ROM family code bit by bit first,
						-- check if anyone has answered later
						write_data((0 => FAMILY_CODE_DS2502_E48(rom_search_bit)));
						after_wait_state <= RX_ROM_BIT;
						if ow_ack_i = '1' then
							if rom_search_bit < 7 then
								rom_search_bit <= rom_search_bit + 1;
							else
								-- After selecting all devices with the DS2502-E48 family code, single one out
								after_wait_state <= RX_ROM_BIT;
							end if;
						end if;
					when RX_ROM_BIT =>
						-- Again read two bits
						read_data("001");
						after_wait_state <= TX_ROM_BIT;
						if ow_ack_i = '1' then
							debug_fifo_we_o   <= '1';
							debug_fifo_data_o <= ow_data_read_i;

							if ow_data_read_i(0) = '1' and ow_data_read_i(1) = '1' then
								-- If both received bits are one: No device is participating in the search at all
								-- Try it again then
								after_wait_state <= RESET_IC;
							end if;
						-- If both are zero, this just means that more than one DS2502-E48 device has answered
						-- -> not a problem
						end if;
					when TX_ROM_BIT =>
						-- Proceed with the received ROM bit
						-- If more than one DS2502-E48 is on the bus, this will select the one with the
						-- lower serial number
						write_data((0 => ow_data_read_i(0)));
						after_wait_state <= RX_ROM_BIT;
						if ow_ack_i = '1' then
							if rom_search_bit < 63 then
								rom_search_bit <= rom_search_bit + 1;
							else
								-- Theoretically, the device should be selected and ready to accept memory commands now...
								after_wait_state <= TX_READ_MEMORY;
							end if;
						end if;
					when TX_READ_MEMORY =>
						write_data(COMMAND_DS2502_READ_MEMORY);
						after_wait_state <= TX_MEMORY_ADDRESS_LO;
					when TX_MEMORY_ADDRESS_LO =>
						-- Start at address zero and read the whole block to verify the CRC16
						write_data(x"00");
						after_wait_state <= TX_MEMORY_ADDRESS_HI;
					when TX_MEMORY_ADDRESS_HI =>
						write_data(x"00");
						after_wait_state <= RX_COMMAND_CRC;
					when RX_COMMAND_CRC =>
						read_data;
						after_wait_state <= RX_DATA;
						received_bytes   <= 0;
						udp_crc          <= (others => '0');
						-- Verify the CRC8 of the command and address bytes
						if ow_ack_i = '1' and ow_data_read_i /= READ_MEMORY_CRC8 then
							-- Try again on mismatch
							after_wait_state <= RESET_IC;
						end if;
						if ow_ack_i = '1' then
							debug_fifo_we_o   <= '1';
							debug_fifo_data_o <= ow_data_read_i;
						end if;
					when RX_DATA =>
						read_data;
						if ow_ack_i = '1' then
							-- Update CRC16
							udp_crc <= update_crc(udp_crc, ow_data_read_i, CRC16_POLYNOMIAL);

							-- Advance byte position
							if received_bytes < 12 then
								received_bytes <= received_bytes + 1;
							else
								after_wait_state <= VERIFY_CRC;
							end if;

							-- Verify block length
							if received_bytes = 0 and ow_data_read_i /= std_ulogic_vector(to_unsigned(NODE_ADDRESS_BLOCK_LENGTH, 8)) then
								-- Try again
								after_wait_state <= RESET_IC;
							end if;

							-- Read out MAC address
							if received_bytes >= 5 and received_bytes < 5 + 6 then
								new_mac_address := mac_address;
								set_byte(new_mac_address, 5 - (received_bytes - 5), ow_data_read_i);
								mac_address       <= new_mac_address;
								debug_fifo_we_o   <= '1';
								debug_fifo_data_o <= ow_data_read_i;
							end if;
						end if;
					when VERIFY_CRC =>
						state <= DONE;
						-- CRC16 is inverted, so final value will not be all-zeroes 
						if udp_crc /= reverse_vector(CRC16_POSTINVERT_MAGIC) then
							-- CRC16 did not match, try again
							state             <= RESET_IC;
							debug_fifo_we_o   <= '1';
							debug_fifo_data_o <= x"99";
						end if;
					when WAIT_ACK_LOW =>
						ow_req_o <= '0';
						if ow_ack_i = '0' then
							state <= after_wait_state;
						end if;
					when DONE =>
						mac_address_ready_o <= '1';
				end case;
			end if;
		end if;
	end process;

end architecture;
