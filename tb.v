`timescale 1ns/1ps
// ============================================================================
// Self-checking testbench for cpu_req_reg
//   - Cache model with programmable wait states (drives `ready`)
//   - Scoreboard: every accepted CPU request must reach the cache, in order, unchanged
//   - Hold-stable checker: held request must not change while stalled
//   - Handshake checker: cpu_ready == ~stall_cpu == ~(req_valid & ~ready)
//   - $monitor for a text log, $dumpfile/$dumpvars for a VCD waveform
// ============================================================================
module tb_cpu_req_reg;

    // ------------------------------------------------------------------ DUT I/O
    reg         clk = 1'b0;
    reg         rst_n;

    reg         cpu_valid;
    reg  [31:0] cpu_addr;
    reg  [31:0] cpu_wdata;
    reg         cpu_we;
    wire        cpu_ready;
    wire        stall_cpu;

    wire        ready;                 // driven by the cache model below
    wire        req_valid;
    wire [31:0] req_addr;
    wire [31:0] req_wdata;
    wire        req_we;

    cpu_req_reg dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .cpu_valid (cpu_valid),
        .cpu_addr  (cpu_addr),
        .cpu_wdata (cpu_wdata),
        .cpu_we    (cpu_we),
        .cpu_ready (cpu_ready),
        .stall_cpu (stall_cpu),
        .ready     (ready),
        .req_valid (req_valid),
        .req_addr  (req_addr),
        .req_wdata (req_wdata),
        .req_we    (req_we)
    );

    // ------------------------------------------------------------------ clock
    always #5 clk = ~clk;              // 10 ns period

    // ------------------------------------------------------------------ cache model
    // ready is high when wait_cnt == 0 (and the TB is not blocking the cache).
    // After each accepted request, wait_cnt reloads with `wait_states`.
    integer wait_states = 0;           // wait states per request (set by the TB)
    integer wait_cnt    = 0;
    reg     cache_block = 1'b0;        // 1 = cache refuses everything (forces a stall)

    assign ready = (wait_cnt == 0) & ~cache_block;

    // ------------------------------------------------------------------ scoreboard
    reg [31:0] exp_addr  [0:255];
    reg [31:0] exp_wdata [0:255];
    reg        exp_we    [0:255];
    integer    wr_ptr = 0;             // requests accepted from the CPU
    integer    rd_ptr = 0;             // requests delivered to the cache
    integer    errors = 0;
    integer    stall_cycles = 0;
    integer    transfers = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            wait_cnt <= 0;
        end else if (req_valid && ready) begin
            // ---- a transfer to the cache happens on this edge ----
            transfers = transfers + 1;
            if (rd_ptr == wr_ptr) begin
                errors = errors + 1;
                $display("[%0t] ERROR: cache received a request nobody sent", $time);
            end else begin
                if (req_addr !== exp_addr[rd_ptr] ||
                    req_wdata !== exp_wdata[rd_ptr] ||
                    req_we   !== exp_we[rd_ptr]) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: request #%0d mismatch  got {%h,%h,%b}  exp {%h,%h,%b}",
                             $time, rd_ptr, req_addr, req_wdata, req_we,
                             exp_addr[rd_ptr], exp_wdata[rd_ptr], exp_we[rd_ptr]);
                end
                rd_ptr = rd_ptr + 1;
            end
            wait_cnt <= wait_states;
        end else if (req_valid && wait_cnt != 0) begin
            wait_cnt <= wait_cnt - 1;
        end
    end

    // ------------------------------------------------------------------ checkers
    reg [66:0] prev_req;               // {valid, addr, wdata, we} from the previous edge
    reg        prev_stall = 1'b0;
    reg        prev_rst_n = 1'b0;

    always @(posedge clk) begin
        // handshake relationships
        if (stall_cpu !== (req_valid & ~ready)) begin
            errors = errors + 1;
            $display("[%0t] ERROR: stall_cpu != req_valid & ~ready", $time);
        end
        if (cpu_ready !== ~stall_cpu) begin
            errors = errors + 1;
            $display("[%0t] ERROR: cpu_ready != ~stall_cpu", $time);
        end
        // hold-stable: if we were stalled last cycle, the request must be unchanged now
        // (skipped around reset, which is allowed to clear it)
        if (prev_stall && rst_n && prev_rst_n &&
            prev_req !== {req_valid, req_addr, req_wdata, req_we}) begin
            errors = errors + 1;
            $display("[%0t] ERROR: held request changed during a stall", $time);
        end
        prev_req   <= {req_valid, req_addr, req_wdata, req_we};
        prev_stall <= stall_cpu;
        prev_rst_n <= rst_n;
    end

    // ------------------------------------------------------------------ CPU tasks
    // Present one request and keep it stable until the register accepts it
    // (accepted on a rising edge where cpu_valid & cpu_ready).
    task send(input [31:0] a, input [31:0] w, input we);
        begin
            cpu_valid = 1'b1;
            cpu_addr  = a;
            cpu_wdata = w;
            cpu_we    = we;
            @(posedge clk);                         // pre-edge values are visible here
            while (!cpu_ready) begin
                stall_cycles = stall_cycles + 1;
                @(posedge clk);
            end
            exp_addr [wr_ptr] = a;                  // accepted: record for the scoreboard
            exp_wdata[wr_ptr] = w;
            exp_we   [wr_ptr] = we;
            wr_ptr = wr_ptr + 1;
            #1;                                     // move off the clock edge before next drive
        end
    endtask

    // CPU idle for n cycles
    task idle(input integer n);
        begin
            cpu_valid = 1'b0;
            repeat (n) @(posedge clk);
            #1;
        end
    endtask

    // Wait until every accepted request has reached the cache
    task drain;
        integer n;
        begin
            cpu_valid = 1'b0;
            n = 0;
            while (rd_ptr != wr_ptr && n < 200) begin
                @(posedge clk);
                n = n + 1;
            end
            if (rd_ptr != wr_ptr) begin
                errors = errors + 1;
                $display("[%0t] ERROR: drain timeout, %0d request(s) never delivered",
                         $time, wr_ptr - rd_ptr);
            end
            repeat (2) @(posedge clk);
            #1;
        end
    endtask

    // ------------------------------------------------------------------ monitor
    initial begin
        $monitor("%0t | rst_n=%b | CPU: v=%b a=%h wd=%h we=%b rdy=%b stall=%b | REG: v=%b a=%h wd=%h we=%b | cache ready=%b",
                 $time, rst_n,
                 cpu_valid, cpu_addr, cpu_wdata, cpu_we, cpu_ready, stall_cpu,
                 req_valid, req_addr, req_wdata, req_we, ready);
    end

    // ------------------------------------------------------------------ waves
    initial begin
        $dumpfile("tb_cpu_req_reg.vcd");
        $dumpvars(0, tb_cpu_req_reg);
    end

    // ------------------------------------------------------------------ watchdog
    initial begin
        #50000;
        $display("TIMEOUT: simulation hung");
        $finish;
    end

    // ------------------------------------------------------------------ main test
    initial begin
        rst_n     = 1'b0;
        cpu_valid = 1'b0;
        cpu_addr  = 32'b0;
        cpu_wdata = 32'b0;
        cpu_we    = 1'b0;

        // ---- Reset ----
        repeat (3) @(posedge clk);
        #3 rst_n = 1'b1;
        #1;
        if (req_valid !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: req_valid not 0 after reset");
        end

        // ---- Phase 1: zero wait states, back-to-back (full throughput) ----
        $display("\n=== PHASE 1: 0 wait states, back-to-back ===");
        wait_states = 0;
        send(32'h1000_0000, 32'hA5A5_0001, 1'b1);
        send(32'h1000_0004, 32'hA5A5_0002, 1'b0);
        send(32'h1000_0008, 32'hA5A5_0003, 1'b1);
        send(32'h1000_000C, 32'hA5A5_0004, 1'b1);
        drain;

        // ---- Phase 2: slow cache, 3 wait states ----
        $display("\n=== PHASE 2: slow cache, 3 wait states ===");
        wait_states = 3;
        send(32'h2000_0000, 32'hB5B5_0001, 1'b1);
        send(32'h2000_0004, 32'hB5B5_0002, 1'b0);
        send(32'h2000_0008, 32'hB5B5_0003, 1'b1);
        send(32'h2000_000C, 32'hB5B5_0004, 1'b0);
        drain;

        // ---- Phase 3: gaps between requests, mixed latency ----
        $display("\n=== PHASE 3: gaps and mixed latency ===");
        wait_states = 1;
        send(32'h3000_0000, 32'hC5C5_0001, 1'b1);
        idle(2);
        send(32'h3000_0004, 32'hC5C5_0002, 1'b0);
        wait_states = 4;
        send(32'h3000_0008, 32'hC5C5_0003, 1'b1);
        idle(1);
        wait_states = 0;
        send(32'h3000_000C, 32'hC5C5_0004, 1'b1);
        send(32'h3000_0010, 32'hC5C5_0005, 1'b0);
        drain;

        // ---- Phase 4: reset while a request is held ----
        $display("\n=== PHASE 4: reset while a request is held ===");
        wait_states = 0;
        cache_block = 1'b1;                         // cache refuses everything
        send(32'h4000_0000, 32'hD5D5_0001, 1'b1);   // A: loads into the empty register
        cpu_valid = 1'b1;                           // B: offered, but must be refused
        cpu_addr  = 32'h4000_0004;
        cpu_wdata = 32'hD5D5_0002;
        cpu_we    = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        if (cpu_ready !== 1'b0 || req_addr !== 32'h4000_0000) begin
            errors = errors + 1;
            $display("ERROR: expected A held and CPU stalled");
        end
        #2 rst_n = 1'b0;                            // async reset in the middle of a stall
        #1;
        if (req_valid !== 1'b0 || cpu_ready !== 1'b1) begin
            errors = errors + 1;
            $display("ERROR: reset did not clear the held request immediately");
        end
        rd_ptr = wr_ptr;                            // A was dropped by reset: nothing expected
        repeat (2) @(posedge clk);
        #3 rst_n = 1'b1;
        cpu_valid   = 1'b0;
        cache_block = 1'b0;
        idle(2);

        // ---- Phase 5: normal operation after reset ----
        $display("\n=== PHASE 5: normal operation after reset ===");
        wait_states = 2;
        send(32'h5000_0000, 32'hE5E5_0001, 1'b1);
        send(32'h5000_0004, 32'hE5E5_0002, 1'b0);
        send(32'h5000_0008, 32'hE5E5_0003, 1'b1);
        drain;

        // ---- Summary ----
        $display("\n=============== SUMMARY ===============");
        $display("requests accepted : %0d", wr_ptr);
        $display("requests delivered: %0d", rd_ptr);
        $display("transfers seen    : %0d", transfers);
        $display("CPU stall cycles  : %0d", stall_cycles);
        $display("errors            : %0d", errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

endmodule
