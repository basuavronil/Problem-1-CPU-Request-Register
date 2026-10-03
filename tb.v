`timescale 1ns/1ps
module tb_cpu_req_reg;

    reg         clk, rst_n;
    reg         cpu_valid, cpu_we;
    reg  [31:0] cpu_addr;
    reg  [31:0] cpu_wdata;
    reg         ready;
    wire        stall_cpu, req_valid, req_we;
    wire [31:0] req_addr;
    wire [31:0] req_wdata;

    cpu_req_reg dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_valid(cpu_valid), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_we(cpu_we),
        .stall_cpu(stall_cpu),
        .ready(ready),
        .req_valid(req_valid), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_we(req_we)
    );

    // clock
    initial clk = 0;
    always #5 clk = ~clk;

    // waveform dump
    initial begin
        $dumpfile("cpu_req_reg.vcd");
        $dumpvars(0, tb_cpu_req_reg);
    end

    // monitor
    initial begin
        $monitor("t=%0t | cpu: v=%b we=%b a=%h d=%h | stall=%b ready=%b | held: v=%b we=%b a=%h d=%h",
                 $time, cpu_valid, cpu_we, cpu_addr, cpu_wdata,
                 stall_cpu, ready,
                 req_valid, req_we, req_addr, req_wdata);
    end

    // ---------------- Cache model: asserts ready after 'wait_states' cycles
    integer wait_states;
    integer wait_cnt;
    initial begin wait_states = 0; wait_cnt = 0; ready = 0; end

    always @(negedge clk) begin
        if (rst_n && req_valid) begin
            if (wait_cnt >= wait_states) begin
                ready    = 1;
                wait_cnt = 0;
            end else begin
                ready    = 0;
                wait_cnt = wait_cnt + 1;
            end
        end else begin
            ready    = 0;
            wait_cnt = 0;
        end
    end

    // ---------------- Scoreboard
    reg [31:0] exp_addr  [0:63];
    reg [31:0] exp_wdata [0:63];
    reg        exp_we    [0:63];
    integer wr_ptr, rd_ptr, errors, consumed;

    initial begin wr_ptr = 0; rd_ptr = 0; errors = 0; consumed = 0; end

    // Check each request when the cache consumes it
    always @(posedge clk) begin
        if (rst_n && req_valid && ready) begin
            if (req_addr  !== exp_addr[rd_ptr]  ||
                req_wdata !== exp_wdata[rd_ptr] ||
                req_we    !== exp_we[rd_ptr]) begin
                errors = errors + 1;
                $display("ERROR @%0t: got a=%h d=%h we=%b, expected a=%h d=%h we=%b",
                         $time, req_addr, req_wdata, req_we,
                         exp_addr[rd_ptr], exp_wdata[rd_ptr], exp_we[rd_ptr]);
            end
            rd_ptr   = rd_ptr + 1;
            consumed = consumed + 1;
        end
    end

    // Hold-stable check: if stalled last cycle, outputs must not change
    reg        p_stall, p_valid, p_we;
    reg [31:0] p_addr;
    reg [31:0] p_wdata;
    initial p_stall = 0;
    always @(posedge clk) begin
        if (rst_n && p_stall) begin
            if (req_valid !== p_valid || req_addr !== p_addr ||
                req_wdata !== p_wdata || req_we   !== p_we) begin
                errors = errors + 1;
                $display("ERROR @%0t: held request changed during stall", $time);
            end
        end
        p_stall = stall_cpu;
        p_valid = req_valid; p_addr = req_addr;
        p_wdata = req_wdata; p_we = req_we;
    end

    // ---------------- CPU driver tasks
    // Presents a request and keeps it until the register accepts it (stall low)
    task send_req(input [31:0] a, input [31:0] d, input w);
        begin
            @(negedge clk);
            cpu_valid = 1; cpu_addr = a; cpu_wdata = d; cpu_we = w;
            #1;
            while (stall_cpu) begin
                @(negedge clk);
                #1;
            end
            // accepted on the coming posedge: record expectation
            exp_addr[wr_ptr]  = a;
            exp_wdata[wr_ptr] = d;
            exp_we[wr_ptr]    = w;
            wr_ptr = wr_ptr + 1;
        end
    endtask

    task cpu_idle(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                cpu_valid = 0; cpu_addr = 0; cpu_wdata = 0; cpu_we = 0;
            end
        end
    endtask

    // ---------------- Test sequence
    initial begin
        cpu_valid = 0; cpu_addr = 0; cpu_wdata = 0; cpu_we = 0;
        rst_n = 0;
        #12 rst_n = 1;

        // Phase 1: cache always ready (0 wait states), back-to-back requests
        wait_states = 0;
        send_req(32'h0000_0010, 32'hAAAA_0001, 1);
        send_req(32'h0000_0014, 32'hAAAA_0002, 0);
        send_req(32'h0000_0018, 32'hAAAA_0003, 1);
        cpu_idle(4);

        // Phase 2: cache slow (3 wait states), CPU must stall and hold
        wait_states = 3;
        send_req(32'h0000_0100, 32'hBBBB_0001, 1);
        send_req(32'h0000_0104, 32'hBBBB_0002, 1);
        send_req(32'h0000_0108, 32'hBBBB_0003, 0);
        send_req(32'h0000_010C, 32'hBBBB_0004, 1);
        cpu_idle(10);

        // Phase 3: gaps between requests with mixed latency
        wait_states = 1;
        send_req(32'h0000_0200, 32'hCCCC_0001, 0);
        cpu_idle(3);
        send_req(32'h0000_0204, 32'hCCCC_0002, 1);
        cpu_idle(8);

        // Phase 4: reset while a request is held
        wait_states = 6;
        send_req(32'h0000_0300, 32'hDDDD_0001, 1);
        cpu_idle(1);
        @(negedge clk); rst_n = 0;
        @(negedge clk); rst_n = 1;
        if (req_valid !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: req_valid not cleared by reset");
        end
        // discard the expectation for the request killed by reset
        rd_ptr = wr_ptr;

        // Phase 5: normal operation after reset
        wait_states = 0;
        send_req(32'h0000_0400, 32'hEEEE_0001, 1);
        cpu_idle(5);

        // Summary
        if (errors == 0 && rd_ptr == wr_ptr)
            $display("PASS: %0d requests consumed in order, no errors", consumed);
        else
            $display("FAIL: errors=%0d, issued=%0d, consumed_ptr=%0d", errors, wr_ptr, rd_ptr);
        $finish;
    end

    // timeout guard
    initial begin
        #20000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
