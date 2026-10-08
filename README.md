<img width="1383" height="679" alt="image" src="https://github.com/user-attachments/assets/82283a0e-fe10-495a-b3c8-b0c2b3bf20b2" />

# CPU Request Register (`cpu_req_reg`)

> A small register stage that latches the CPU's request `{addr, wdata, we, valid}` and holds it unchanged until the cache asserts `ready`, raising `stall_cpu` while the CPU has to wait

```text
                    clk      rst_n
                     |         |
                     v         v
               +------------------------------+
 cpu_valid --->|  req_valid  : 1 bit          |---> req_valid
 cpu_addr  --->|  req_addr   : 32 bits        |---> req_addr
 cpu_wdata --->|  req_wdata  : 32 bits        |---> req_wdata
 cpu_we    --->|  req_we     : 1 bit          |---> req_we
               |                              |
 stall_cpu <---|  stall = req_valid & ~ready  |<--- ready
               +------------------------------+
                        cpu_req_reg
```

## Why this block exists

The CPU and the cache do not always run at the same pace. If the cache is busy, the CPU's request must not be lost or changed. This register sits between them, keeps the request stable, and tells the CPU when to wait.

## Ports

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Asynchronous active-low reset, clears the held request |
| `cpu_valid` | in | 1 | CPU has a request this cycle |
| `cpu_addr` | in | 32 | CPU address |
| `cpu_wdata` | in | 32 | CPU write data |
| `cpu_we` | in | 1 | 1 = store, 0 = load |
| `ready` | in | 1 | Cache accepts the held request this cycle |
| `stall_cpu` | out | 1 | High when a request is held and the cache is not ready |
| `req_valid` | out | 1 | Held request is valid (to cache) |
| `req_addr` | out | 32 | Held address |
| `req_wdata` | out | 32 | Held write data |
| `req_we` | out | 1 | Held write enable |

## How it works

The block has one internal condition that controls everything:

```verilog
assign stall_cpu = req_valid & ~ready;
```

In words: **the CPU must stall only when the register already holds a request and the cache has not taken it yet.**

On every rising clock edge the register looks at `rst_n` and `stall_cpu`, and does exactly one of three things.

### Condition 1: Reset (`rst_n = 0`)

Asynchronous. All held values are cleared and `req_valid` goes to 0, even in the middle of a stall. Any request that was being held is dropped.

### Condition 2: Stalled (`stall_cpu = 1`)

This happens when `req_valid = 1` and `ready = 0`.

- All held outputs (`req_valid`, `req_addr`, `req_wdata`, `req_we`) stay frozen.
- The CPU's new request is **not** captured. The CPU must keep presenting it until `stall_cpu` drops.

### Condition 3: Not stalled (`stall_cpu = 0`)

The register is free to load. `req_valid` takes the value of `cpu_valid` on every such edge, and the data fields load only if `cpu_valid = 1`. This covers two situations:

| Situation | `req_valid` | `ready` | What happens on the clock edge |
|---|---|---|---|
| Register empty | 0 | x | If `cpu_valid = 1`, the request is latched. Otherwise nothing is held. |
| Held request accepted | 1 | 1 | The cache consumes the held request. If `cpu_valid = 1`, the next request loads on the same edge (back-to-back, no bubble). If `cpu_valid = 0`, the register empties. |

### Summary table

| `rst_n` | `req_valid` | `ready` | `stall_cpu` | Action |
|---|---|---|---|---|
| 0 | x | x | x | Clear everything |
| 1 | 0 | x | 0 | Load CPU request if `cpu_valid` |
| 1 | 1 | 0 | 1 | **Hold**, CPU waits |
| 1 | 1 | 1 | 0 | Request consumed, load next or empty |

## The core of the RTL

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        req_valid <= 1'b0;
        req_addr  <= 32'b0;
        req_wdata <= 32'b0;
        req_we    <= 1'b0;
    end else if (!stall_cpu) begin
        req_valid <= cpu_valid;
        if (cpu_valid) begin
            req_addr  <= cpu_addr;
            req_wdata <= cpu_wdata;
            req_we    <= cpu_we;
        end
    end
    // else: stalled, hold everything
end
```

Things worth noticing:

- **No explicit "hold" code.** Holding happens because the `else if (!stall_cpu)` branch is skipped, so the registers keep their value.
- **`req_valid` always follows `cpu_valid` when not stalled.** This is what empties the register after a request is accepted and no new one is waiting.
- **Data fields keep old values when `cpu_valid = 0`.** They are not cleared, but they are meaningless because `req_valid` is 0. Downstream logic must qualify them with `req_valid`.
- **`stall_cpu` is combinational from `ready`.** If the cache's `ready` comes late in the cycle, this path can become timing critical.

## Example behavior

| Cycle | `cpu_valid` | `ready` | `req_valid` (after edge) | `stall_cpu` | Comment |
|---|---|---|---|---|---|
| 1 | 1 (A) | 0 | 1 (A) | 0 | A latched, register was empty |
| 2 | 1 (B) | 0 | 1 (A) | 1 | Stalled, B not taken, A held |
| 3 | 1 (B) | 0 | 1 (A) | 1 | Still stalled |
| 4 | 1 (B) | 1 | 1 (B) | 0 | A consumed, B loaded back-to-back |
| 5 | 0 | 1 | 0 | 0 | B consumed, register empties |

## Files

| File | Purpose |
|---|---|
| `cpu_req_reg.v` | Synthesizable RTL |
| `tb_cpu_req_reg.v` | Self-checking testbench with `$monitor` and VCD dump |
| `docs/cpu_req_reg_diagram.svg` | Block diagram used above |

## Verification

The testbench includes:

- A **cache model** with a programmable number of wait states before `ready`.
- A **scoreboard** that checks every request reaches the cache in order and unchanged.
- A **hold-stable checker** that flags any change in the held request during a stall.
- Five phases: zero wait states, slow cache (3 wait states), gaps with mixed latency, reset while a request is held, and normal operation after reset.

<img width="457" height="326" alt="image" src="https://github.com/user-attachments/assets/e1323bf4-76ac-485e-9b88-65ab9b015eba" />


lid` clears immediately.
