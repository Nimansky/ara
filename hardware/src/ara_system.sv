// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
// Description:
// Ara's System, containing Ariane and Ara.

module ara_system import axi_pkg::*; import ara_pkg::*; #(
    // RVV Parameters
    parameter int                      unsigned NrLanes            = 0,                               // Number of parallel vector lanes.
    parameter int                      unsigned VLEN               = 0,                               // VLEN [bit]
    parameter int                      unsigned OSSupport          = 1,                               // Support for floating-point data types
    parameter fpu_support_e                     FPUSupport         = FPUSupportHalfSingleDouble,
    // External support for vfrec7, vfrsqrt7
    parameter fpext_support_e                   FPExtSupport       = FPExtSupportEnable,
    // Support for fixed-point data types
    parameter fixpt_support_e                   FixPtSupport       = FixedPointEnable,
    // Support for segment memory operations
    parameter seg_support_e                     SegSupport         = SegSupportEnable,
    // Ariane configuration
    parameter config_pkg::cva6_cfg_t            CVA6Cfg            = cva6_config_pkg::cva6_cfg,
    // CVA6-related parameters
    parameter type                              exception_t        = logic,
    parameter type                              accelerator_req_t  = logic,
    parameter type                              accelerator_resp_t = logic,
    parameter type                              acc_mmu_req_t      = logic,
    parameter type                              acc_mmu_resp_t     = logic,
    parameter type                              cva6_to_acc_t      = logic,
    parameter type                              acc_to_cva6_t      = logic,
    // AXI Interface
    parameter int                      unsigned AxiAddrWidth       = 64,
    parameter int                      unsigned AxiIdWidth         = 6,
    parameter int                      unsigned AxiNarrowDataWidth = 64,
    parameter int                      unsigned AxiWideDataWidth   = 64*NrLanes/2,
    parameter type                              ariane_axi_ar_t    = logic,
    parameter type                              ariane_axi_r_t     = logic,
    parameter type                              ariane_axi_aw_t    = logic,
    parameter type                              ariane_axi_w_t     = logic,
    parameter type                              ariane_axi_b_t     = logic,
    parameter type                              ariane_axi_req_t   = logic,
    parameter type                              ariane_axi_resp_t  = logic,
    parameter type                              ara_axi_ar_t       = logic,
    parameter type                              ara_axi_r_t        = logic,
    parameter type                              ara_axi_aw_t       = logic,
    parameter type                              ara_axi_w_t        = logic,
    parameter type                              ara_axi_b_t        = logic,
    parameter type                              ara_axi_req_t      = logic,
    parameter type                              ara_axi_resp_t     = logic,
    parameter type                              system_axi_ar_t    = logic,
    parameter type                              system_axi_r_t     = logic,
    parameter type                              system_axi_aw_t    = logic,
    parameter type                              system_axi_w_t     = logic,
    parameter type                              system_axi_b_t     = logic,
    parameter type                              system_axi_req_t   = logic,
    parameter type                              system_axi_resp_t  = logic,
    // VTrace interface
    parameter type                              soc_wide_lite_req_t  = logic,
    parameter type                              soc_wide_lite_resp_t = logic,
    // DO NOT change
    localparam type                   vlen_t       = logic[$clog2(VLEN+1)-1:0],
  ) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic             [63:0] boot_addr_i,
    input                     [2:0] hart_id_i,
    // Scan chain
    input  logic                    scan_enable_i,
    input  logic                    scan_data_i,
    output logic                    scan_data_o,
    // AXI Interface
    output system_axi_req_t         axi_req_o,
    input  system_axi_resp_t        axi_resp_i,
    // VTRACE AXI interface
    input soc_wide_lite_req_t        vtrace_axi_req_i,
    output soc_wide_lite_resp_t      vtrace_axi_resp_o
  );

  `include "axi/assign.svh"
  `include "axi/typedef.svh"

  // Interfaces between Ara's dispatcher and Ara's backend
  typedef struct packed {
    ara_op_e op; // Operation

    // Stores and slides do not re-shuffle the
    // source registers. In these two cases, vl refers
    // to the target EEW and vtype.vsew, respectively.
    // Since operand requesters work with the old
    // eew of the source registers, we should rescale
    // vl to the old eew to fetch the correct number of Bytes.
    //
    // Another solution would be to pass directly the target
    // eew (vstores) or the vtype.vsew (vslides), but this would
    // create confusion with the current naming convention
    logic scale_vl;

    // Mask vector register operand
    logic vm;
    rvv_pkg::vew_e eew_vmask;

    // 1st vector register operand
    logic [4:0] vs1;
    logic use_vs1;
    opqueue_conversion_e conversion_vs1;
    rvv_pkg::vew_e eew_vs1;
    rvv_pkg::vew_e old_eew_vs1;

    // 2nd vector register operand
    logic [4:0] vs2;
    logic use_vs2;
    opqueue_conversion_e conversion_vs2;
    rvv_pkg::vew_e eew_vs2;

    // Use vd as an operand as well (e.g., vmacc)
    logic use_vd_op;
    rvv_pkg::vew_e eew_vd_op;

    // Scalar operand
    elen_t scalar_op;
    logic use_scalar_op;

    // 2nd scalar operand: stride for constant-strided vector load/stores, slide offset for vector
    // slides
    elen_t stride;
    logic is_stride_np2;

    // Destination vector register
    logic [4:0] vd;
    logic use_vd;

    // If asserted: vs2 is kept in MulFPU opqueue C, and vd_op in MulFPU A
    logic swap_vs2_vd_op;

    // Effective length multiplier
    rvv_pkg::vlmul_e emul;

    // Number of segments in segment mem op
    logic [2:0] nf;

    // Is this a fault-only-first load?
    logic fault_only_first;

    // Rounding-Mode for FP operations
    fpnew_pkg::roundmode_e fp_rm;
    // Widen FP immediate (re-encoding)
    logic wide_fp_imm;
    // Resizing of FP conversions
    resize_e cvt_resize;

    // Vector machine metadata
    vlen_t vl;
    vlen_t vstart;
    rvv_pkg::vtype_t vtype;

    // Request token, for registration in the sequencer
    logic token;
  } ara_req_t;

  typedef struct packed {
    // Scalar response
    elen_t resp;

    // Instruction triggered an exception
    exception_t exception;

    // Fault-only-first exception on element whose idx > 0
    logic fof_exception;

    // New value for vstart
    vlen_t exception_vstart;
  } ara_resp_t;


  ///////////
  //  AXI  //
  ///////////

  ariane_axi_req_t  ariane_narrow_axi_req;
  ariane_axi_resp_t ariane_narrow_axi_resp;
  ara_axi_req_t     ariane_axi_req, ara_axi_req_inval, ara_axi_req;
  ara_axi_resp_t    ariane_axi_resp, ara_axi_resp_inval, ara_axi_resp;

  //////////////////////
  //  Ara and Ariane  //
  //////////////////////

  // Accelerator ports
  cva6_to_acc_t        acc_req;
  acc_to_cva6_t        acc_resp;
  logic                                 acc_resp_valid;
  logic                                 acc_resp_ready;
  logic                                 acc_cons_en;
  logic              [AxiAddrWidth-1:0] inval_addr;
  logic                                 inval_valid;
  logic                                 inval_ready;

  assign vtrace_acc_req_o = acc_req;

  // Support max 8 cores, for now
  logic [63:0] hart_id;
  assign hart_id = {'0, hart_id_i};

  // Pack invalidation interface into acc interface
  acc_to_cva6_t acc_resp_pack;
  always_comb begin : pack_inval
    acc_resp_pack                      = acc_resp;
    acc_resp_pack.acc_resp.inval_valid = inval_valid;
    acc_resp_pack.acc_resp.inval_addr  = inval_addr;
    inval_ready                        = acc_req.acc_req.inval_ready;
    acc_cons_en                        = acc_req.acc_req.acc_cons_en;
  end

`ifdef IDEAL_DISPATCHER
  // Perfect dispatcher to Ara
  accel_dispatcher_ideal i_accel_dispatcher_ideal #(
    .CVA6Cfg(CVA6Cfg),
    .cva6_to_acc_t(cva6_to_acc_t),
    .acc_to_cva6_t(acc_to_cva6_t)
  ) i_accel_dispatcher_ideal (
    .clk_i            (clk_i                 ),
    .rst_ni           (rst_ni                ),
    .acc_req_o        (acc_req               ),
    .acc_resp_i       (acc_resp              )
  );
`else
  cva6 #(
    .CVA6Cfg          (CVA6Cfg           ),
    .cvxif_req_t      (cva6_to_acc_t     ),
    .cvxif_resp_t     (acc_to_cva6_t     ),
    .axi_ar_chan_t    (ariane_axi_ar_t   ),
    .axi_aw_chan_t    (ariane_axi_aw_t   ),
    .axi_w_chan_t     (ariane_axi_w_t    ),
    .b_chan_t         (ariane_axi_b_t    ),
    .r_chan_t         (ariane_axi_r_t    ),
    .noc_req_t        (ariane_axi_req_t  ),
    .noc_resp_t       (ariane_axi_resp_t ),
    .accelerator_req_t (accelerator_req_t),
    .accelerator_resp_t(accelerator_resp_t),
    .acc_mmu_req_t     (acc_mmu_req_t),
    .acc_mmu_resp_t    (acc_mmu_resp_t)
  ) i_ariane (
    .clk_i            (clk_i                   ),
    .rst_ni           (rst_ni                  ),
    .boot_addr_i      (boot_addr_i             ),
    .hart_id_i        (hart_id                 ),
    .irq_i            ('0                      ),
    .ipi_i            ('0                      ),
    .time_irq_i       ('0                      ),
    .debug_req_i      ('0                      ),
    .clic_irq_valid_i ('0                      ),
    .clic_irq_id_i    ('0                      ),
    .clic_irq_level_i ('0                      ),
    .clic_irq_priv_i  (riscv::priv_lvl_t'(2'b0)),
    .clic_irq_shv_i   ('0                      ),
    .clic_irq_ready_o (/* empty */             ),
    .clic_kill_req_i  ('0                      ),
    .clic_kill_ack_o  (/* empty */             ),
    .rvfi_probes_o    (/* empty */             ),
    // Accelerator ports
    .cvxif_req_o      (acc_req                 ),
    .cvxif_resp_i     (acc_resp_pack           ),
    .noc_req_o        (ariane_narrow_axi_req   ),
    .noc_resp_i       (ariane_narrow_axi_resp  )
  );
`endif

  axi_dw_converter #(
    .AxiSlvPortDataWidth(AxiNarrowDataWidth),
    .AxiMstPortDataWidth(AxiWideDataWidth  ),
    .AxiAddrWidth       (AxiAddrWidth      ),
    .AxiIdWidth         (AxiIdWidth        ),
    .AxiMaxReads        (2                 ),
    .ar_chan_t          (ariane_axi_ar_t   ),
    .mst_r_chan_t       (ara_axi_r_t       ),
    .slv_r_chan_t       (ariane_axi_r_t    ),
    .aw_chan_t          (ariane_axi_aw_t   ),
    .b_chan_t           (ariane_axi_b_t    ),
    .mst_w_chan_t       (ara_axi_w_t       ),
    .slv_w_chan_t       (ariane_axi_w_t    ),
    .axi_mst_req_t      (ara_axi_req_t     ),
    .axi_mst_resp_t     (ara_axi_resp_t    ),
    .axi_slv_req_t      (ariane_axi_req_t  ),
    .axi_slv_resp_t     (ariane_axi_resp_t )
  ) i_ariane_axi_dwc (
    .clk_i     (clk_i                 ),
    .rst_ni    (rst_ni                ),
`ifdef IDEAL_DISPATCHER
    .slv_req_i ('0                    ),
`else
    .slv_req_i (ariane_narrow_axi_req ),
`endif
    .slv_resp_o(ariane_narrow_axi_resp),
    .mst_req_o (ariane_axi_req        ),
    .mst_resp_i(ariane_axi_resp       )
  );

  axi_inval_filter #(
    .MaxTxns    (4                              ),
    .AddrWidth  (AxiAddrWidth                   ),
    .L1LineWidth(CVA6Cfg.DCACHE_LINE_WIDTH/8    ),
    .aw_chan_t  (ara_axi_aw_t                   ),
    .req_t      (ara_axi_req_t                  ),
    .resp_t     (ara_axi_resp_t                 )
  ) i_axi_inval_filter (
    .clk_i        (clk_i             ),
    .rst_ni       (rst_ni            ),
`ifdef IDEAL_DISPATCHER
    .en_i         (1'b0              ),
`else
    .en_i         (acc_cons_en       ),
`endif
    .slv_req_i    (ara_axi_req       ),
    .slv_resp_o   (ara_axi_resp      ),
    .mst_req_o    (ara_axi_req_inval ),
    .mst_resp_i   (ara_axi_resp_inval),
    .inval_addr_o (inval_addr        ),
    .inval_valid_o(inval_valid       ),
`ifdef IDEAL_DISPATCHER
    .inval_ready_i(1'b0              )
`else
    .inval_ready_i(inval_ready       )
`endif
  );

  ara_req_t vtrace_ara_req;
  logic vtrace_ara_req_valid;

  ara #(
    .NrLanes           (NrLanes           ),
    .VLEN              (VLEN              ),
    .OSSupport         (OSSupport         ),
    .FPUSupport        (FPUSupport        ),
    .FPExtSupport      (FPExtSupport      ),
    .FixPtSupport      (FixPtSupport      ),
    .SegSupport        (SegSupport        ),
    .CVA6Cfg           (CVA6Cfg           ),
    .exception_t       (exception_t       ),
    .accelerator_req_t (accelerator_req_t ),
    .accelerator_resp_t(accelerator_resp_t),
    .acc_mmu_req_t     (acc_mmu_req_t     ),
    .acc_mmu_resp_t    (acc_mmu_resp_t    ),
    .cva6_to_acc_t     (cva6_to_acc_t     ),
    .acc_to_cva6_t     (acc_to_cva6_t     ),
    .ara_req_t         (ara_req_t         ),
    .ara_resp_t        (ara_resp_t        ),
    .AxiDataWidth      (AxiWideDataWidth  ),
    .AxiAddrWidth      (AxiAddrWidth      ),
    .axi_ar_t          (ara_axi_ar_t      ),
    .axi_r_t           (ara_axi_r_t       ),
    .axi_aw_t          (ara_axi_aw_t      ),
    .axi_w_t           (ara_axi_w_t       ),
    .axi_b_t           (ara_axi_b_t       ),
    .axi_req_t         (ara_axi_req_t     ),
    .axi_resp_t        (ara_axi_resp_t    )
  ) i_ara (
    .clk_i           (clk_i         ),
    .rst_ni          (rst_ni        ),
    .scan_enable_i   (scan_enable_i ),
    .scan_data_i     (1'b0          ),
    .scan_data_o     (/* Unused */  ),
    .acc_req_i       (acc_req       ),
    .acc_resp_o      (acc_resp      ),
    .axi_req_o       (ara_axi_req   ),
    .axi_resp_i      (ara_axi_resp  ),
    .ara_req_o       (vtrace_ara_req),
    .ara_req_valid_o (vtrace_ara_req_valid)
  );

  axi_mux #(
    .SlvAxiIDWidth(AxiIdWidth       ),
    .slv_ar_chan_t(ara_axi_ar_t     ),
    .slv_aw_chan_t(ara_axi_aw_t     ),
    .slv_b_chan_t (ara_axi_b_t      ),
    .slv_r_chan_t (ara_axi_r_t      ),
    .slv_req_t    (ara_axi_req_t    ),
    .slv_resp_t   (ara_axi_resp_t   ),
    .mst_ar_chan_t(system_axi_ar_t  ),
    .mst_aw_chan_t(system_axi_aw_t  ),
    .w_chan_t     (system_axi_w_t   ),
    .mst_b_chan_t (system_axi_b_t   ),
    .mst_r_chan_t (system_axi_r_t   ),
    .mst_req_t    (system_axi_req_t ),
    .mst_resp_t   (system_axi_resp_t),
    .NoSlvPorts   (2                ),
    .SpillAr      (1'b1             ),
    .SpillR       (1'b1             ),
    .SpillAw      (1'b1             ),
    .SpillW       (1'b1             ),
    .SpillB       (1'b1             )
  ) i_system_mux (
    .clk_i      (clk_i                                ),
    .rst_ni     (rst_ni                               ),
    .test_i     (1'b0                                 ),
    .slv_reqs_i ({ara_axi_req_inval, ariane_axi_req}  ),
    .slv_resps_o({ara_axi_resp_inval, ariane_axi_resp}),
    .mst_req_o  (axi_req_o                            ),
    .mst_resp_i (axi_resp_i                           )
  );

  vtrace_top #(
    .CVA6Cfg        (CVA6AraConfig         ),
    .DataWidth      (AxiDataWidth          ),
    .AddrWidth      (AxiAddrWidth          ),
    .axi_lite_req_t (soc_wide_lite_req_t   ),
    .axi_lite_resp_t(soc_wide_lite_resp_t  ),
    .accelerator_req_t (cva6_to_acc_t      ),
    .accelerator_resp_t (acc_to_cva6_t     ),
    .ara_req_t      (ara_req_t             )
  ) i_vtrace (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),

    // AXI
    .axi_lite_slave_req_i (axi_lite_vtrace_req ),
    .axi_lite_slave_resp_o(axi_lite_vtrace_resp),

    // CVA6/Ara interface
    .acc_req_i   (acc_req),
    .acc_resp_i  (acc_resp),
    .ara_req_i   (vtrace_ara_req),
    .ara_req_valid_i (vtrace_ara_req_valid)
  );

endmodule : ara_system
