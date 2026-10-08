// ============================================================================
// cpu_req_reg
// Single-entry request register between a CPU and a cache.
// Holds {addr, wdata, we, valid} unchanged until the cache asserts `ready`.
// The CPU side gets a standard valid/ready handshake (cpu_valid / cpu_ready).
// stall_cpu is kept as the inverse of cpu_ready for stall-style CPU pipelines.
// ============================================================================
module cpu_req_reg (
    input  wire        clk,         // clock
    input  wire        rst_n,       // asynchronous active-low reset

    // ---------------- CPU side ----------------
    input  wire        cpu_valid,   // CPU has a request this cycle
    input  wire [31:0] cpu_addr,    // CPU address
    input  wire [31:0] cpu_wdata,   // CPU write data
    input  wire        cpu_we,      // 1 = store (write), 0 = load (read)
    output wire        cpu_ready,   // register can accept a CPU request this cycle
    output wire        stall_cpu,   // CPU must wait (= ~cpu_ready)

    // ---------------- Cache side ----------------
    input  wire        ready,       // cache can accept the held request this cycle
    output reg         req_valid,   // held request is valid
    output reg  [31:0] req_addr,    // held address
    output reg  [31:0] req_wdata,   // held write data
    output reg         req_we       // held write enable
);

    // Register can take a new request when it is EMPTY,
    // or when the cache is CONSUMING the held request this cycle.
    // A CPU request is accepted on a cycle where cpu_valid & cpu_ready.
    assign cpu_ready = ~req_valid | ready;

    // Same information, stall-style: register is full AND cache is not taking it
    assign stall_cpu = ~cpu_ready;       // = req_valid & ~ready

    // Runs on every rising clock edge, OR immediately when rst_n falls (async reset)
    always @(posedge clk or negedge rst_n) begin

        // PATH 1: RESET. rst_n is active-low, so !rst_n is true when rst_n = 0
        if (!rst_n) begin
            req_valid <= 1'b0;   // no valid request is held after reset
            req_addr  <= 32'b0;  // clear held address
            req_wdata <= 32'b0;  // clear held write data
            req_we    <= 1'b0;   // clear held write enable
        end

        // PATH 2: READY TO LOAD. Reset is off and cpu_ready = 1.
        // The register is either empty, or the cache is consuming its request this cycle.
        else if (cpu_ready) begin
            req_valid <= cpu_valid;      // follow the CPU: 1 if it has a request, 0 if not
                                         // (this empties the register after the cache takes the old request)

            if (cpu_valid) begin         // load the payload only when the CPU really has a request
                req_addr  <= cpu_addr;   // capture the CPU's address
                req_wdata <= cpu_wdata;  // capture the CPU's write data
                req_we    <= cpu_we;     // capture read/write flag
            end
            // if cpu_valid = 0: addr/wdata/we keep old values (ignored, since req_valid = 0)
        end

        // PATH 3: NOT READY (implicit else). Reset is off and cpu_ready = 0
        // (req_valid = 1 and ready = 0). No assignment happens, so every
        // register keeps its value: the request is held until the cache says ready.

    end

endmodule
