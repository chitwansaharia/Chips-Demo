-- One-wire bus master that can send and receive single bits

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.one_wire_types.all;

entity one_wire_master is
	generic(
		-- Clock division factor that should result in a 10 µs pulse clock when derived from clock_i
		CLOCK_DIVIDE_FACTOR : positive
	);
	port(
		clock_i      : in  std_ulogic;
		-- Synchronous reset
		reset_i      : in  std_ulogic;

		-- Four-phase transaction handshake
		req_i        : in  std_ulogic;
		ack_o        : out std_ulogic;

		-- All control signals must remain valid/unchanged from the assertion of req_i to its deassertion
		-- Operation code
		operation_i  : in  t_operation;

		data_read_o  : out std_ulogic;
		data_write_i : in  std_ulogic;

		-- Connect to toplevel one-wire port via tri-state buffer
		one_wire_i   : in  std_ulogic;
		one_wire_o   : out std_ulogic;
		-- Active-high tri-state
		one_wire_t_o : out std_ulogic
	);
end entity;

architecture rtl of one_wire_master is
	type t_state is (
		IDLE,
		IN_READ,
		IN_RESET,
		WAIT_ONGOING_OPERATION,
		WAIT_AFTER_OPERATION,
		DONE
	);

	signal state        : t_state := IDLE;
	signal clock_enable : std_ulogic;

	signal wait_counter : integer range 0 to 100;

	-- Cycle definitions for the different modes
	-- See wait_counter definition for maximum value
	-- One cycle should be 5 µs if CLOCK_DIVIDE_FACTOR is set correctly

	constant CYCLES_RESET_LOW       : integer := 100;
	constant CYCLES_RESET_WAIT_DATA : integer := 20;
	constant CYCLES_RESET_WAIT      : integer := 100;

	constant CYCLES_WRITE_ONE_LOW  : integer := 2;
	constant CYCLES_WRITE_ONE_WAIT : integer := 40;

	constant CYCLES_WRITE_ZERO_LOW  : integer := 20;
	constant CYCLES_WRITE_ZERO_WAIT : integer := 2;

	-- Release after 5 µs
	constant CYCLES_READ_LOW       : integer := 1;
	-- Sample data 15 µs after falling edge
	constant CYCLES_READ_WAIT_DATA : integer := 2;
	constant CYCLES_READ_WAIT      : integer := 20;

begin
	-- Output is always zero, only tri-state is used for signaling
	one_wire_o <= '0';

	-- Divide the clock
	clock_divider_inst : entity work.clock_divider
		generic map(
			DIVIDE_FACTOR => CLOCK_DIVIDE_FACTOR
		)
		port map(
			clock_i        => clock_i,
			reset_i        => reset_i,
			clock_enable_o => clock_enable
		);

	process(clock_i)
	begin
		if rising_edge(clock_i) then
			if reset_i = '1' then
				state        <= IDLE;
				wait_counter <= 0;
				ack_o        <= '0';
				one_wire_t_o <= '1';
			elsif clock_enable = '1' then
				ack_o <= '0';

				case state is
					when IDLE =>
						if req_i = '1' then
							one_wire_t_o <= '0';

							case operation_i is
								when OPERATION_WRITE =>
									state <= WAIT_ONGOING_OPERATION;
									if data_write_i = '0' then
										wait_counter <= CYCLES_WRITE_ZERO_LOW;
									else
										wait_counter <= CYCLES_WRITE_ONE_LOW;
									end if;
								when OPERATION_READ =>
									state        <= IN_READ;
									wait_counter <= CYCLES_READ_LOW;
								when others => -- OPERATION_RESET
									state        <= IN_RESET;
									wait_counter <= CYCLES_RESET_LOW;
							end case;
						end if;
					when IN_RESET =>
						-- Count down to one, not zero, since one delay cycle is introduced
						-- by the state machine anyway
						if wait_counter = 1 then
							one_wire_t_o <= '1';
							state        <= WAIT_ONGOING_OPERATION;
							wait_counter <= CYCLES_RESET_WAIT_DATA;
						end if;
					when IN_READ =>
						if wait_counter = 1 then
							one_wire_t_o <= '1';
							state        <= WAIT_ONGOING_OPERATION;
							wait_counter <= CYCLES_READ_WAIT_DATA;
						end if;
					when WAIT_ONGOING_OPERATION =>
						-- Wait state when an operation is still ongoing
						-- After waiting the requested number of cycles, move 
						-- on to WAIT_AFTER_OPERATION to wait the recovery time
						if wait_counter = 1 then
							state <= WAIT_AFTER_OPERATION;
							case operation_i is
								when OPERATION_WRITE =>
									one_wire_t_o <= '1';
									if data_write_i = '0' then
										wait_counter <= CYCLES_WRITE_ZERO_WAIT;
									else
										wait_counter <= CYCLES_WRITE_ONE_WAIT;
									end if;
								when OPERATION_READ =>
									-- Read actual data
									data_read_o  <= one_wire_i;
									wait_counter <= CYCLES_READ_WAIT;
								when others => -- OPERATION_RESET
									-- Read presence indicator
									data_read_o  <= one_wire_i;
									wait_counter <= CYCLES_RESET_WAIT;
							end case;
						end if;
					when WAIT_AFTER_OPERATION =>
						-- Wait state for recovery after an operation was completed
						if wait_counter = 1 then
							state <= DONE;
						end if;
					when DONE =>
						-- Signal completion, wait for confirmation
						ack_o <= '1';
						if req_i = '0' then
							state <= IDLE;
						end if;
				end case;

				-- When wait_counter = 1 and the counter is loaded with a new value above,
				-- this if statement will keep the new value.
				if wait_counter > 1 then
					wait_counter <= wait_counter - 1;
				end if;
			end if;
		end if;
	end process;

end architecture;
