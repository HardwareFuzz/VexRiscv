`timescale 1ns/1ps
// Simple 1-write / 1-read synchronous RAM for Verilator builds.
// This is a fallback model used by the SMP generator when no technology-specific
// RAM macro is provided.

module Ram_1w_1rs #(
  parameter integer wordCount      = 512,
  parameter integer wordWidth      = 64,
  parameter bit     clockCrossing  = 1'b0,
  parameter string  technology     = "auto",
  parameter string  readUnderWrite = "dontCare",
  parameter integer wrAddressWidth = 9,
  parameter integer wrDataWidth    = 64,
  parameter integer wrMaskWidth    = 8,
  parameter bit     wrMaskEnable   = 1'b1,
  parameter integer rdAddressWidth = 9,
  parameter integer rdDataWidth    = 64,
  parameter integer rdLatency      = 1
) (
  input  wire                       wr_clk,
  input  wire                       wr_en,
  input  wire [wrMaskWidth-1:0]     wr_mask,
  input  wire [wrAddressWidth-1:0]  wr_addr,
  input  wire [wrDataWidth-1:0]     wr_data,
  input  wire                       rd_clk,
  input  wire                       rd_en,
  input  wire [rdAddressWidth-1:0]  rd_addr,
  input  wire                       rd_dataEn,
  output reg  [rdDataWidth-1:0]     rd_data
);

  // Synthesize-friendly memory array.
  reg [wordWidth-1:0] mem [0:wordCount-1];

  integer i;
  always @(posedge wr_clk) begin
    if (wr_en) begin
      if (wrMaskEnable) begin
        for (i = 0; i < wrMaskWidth; i = i + 1) begin
          if (wr_mask[i]) begin
            mem[wr_addr][(i*8) +: 8] <= wr_data[(i*8) +: 8];
          end
        end
      end else begin
        mem[wr_addr] <= wr_data;
      end
    end
  end

  generate
    if (rdLatency == 0) begin : gen_async_read
      always @(*) begin
        if (rd_en && rd_dataEn)
          rd_data = mem[rd_addr];
        else
          rd_data = {rdDataWidth{1'b0}};
      end
    end else begin : gen_sync_read
      always @(posedge rd_clk) begin
        if (rd_en && rd_dataEn)
          rd_data <= mem[rd_addr];
      end
    end
  endgenerate

endmodule
