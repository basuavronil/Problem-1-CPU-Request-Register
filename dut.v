module cpu_req_reg (
    input  wire        clk,
    input  wire        rst_n,

    // CPU side
    input  wire        cpu_valid,
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    input  wire        cpu_we,
    output wire        stall_cpu,

    // Cache side
    input  wire        ready,
    output reg         req_valid,
    output reg  [31:0] req_addr,
    output reg  [31:0] req_wdata,
    output reg         req_we
);

    // Register is full and the cache is not taking it -> CPU must wait
    assign stall_cpu = req_valid & ~ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_valid <= 1'b0;
            req_addr  <= 32'b0;
            req_wdata <= 32'b0;
            req_we    <= 1'b0;
        end else if (!stall_cpu) begin
            // Empty, or being consumed this cycle: take whatever the CPU offers
            req_valid <= cpu_valid;
            if (cpu_valid) begin
                req_addr  <= cpu_addr;
                req_wdata <= cpu_wdata;
                req_we    <= cpu_we;
            end
        end
        // else: stalled, hold everything
    end

endmodule
