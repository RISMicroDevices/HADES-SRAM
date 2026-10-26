from __future__ import annotations

from collections import OrderedDict

from .model import Config


def emit_port_constraints(index: int) -> str:
    inputs = " ".join((
        f"sram{index}_en",
        f"sram{index}_we",
        f"{{sram{index}_addr[*]}}",
        f"{{sram{index}_wdata[*]}}",
        f"{{sram{index}_be[*]}}",
    ))
    outputs = " ".join((
        f"{{sram{index}_rdata[*]}}",
        f"sram{index}_rvalid",
    ))
    lines = [
        "# Define port_clk before sourcing this file; the 0.000 ns external delays must be reviewed for the integration.",
        "# These interface constraints complement the clock-mode XDC and do not constitute timing signoff.",
        f"set sram{index}_input_delay_max_ns 0.000",
        f"set sram{index}_input_delay_min_ns 0.000",
        f"set sram{index}_output_delay_max_ns 0.000",
        f"set sram{index}_output_delay_min_ns 0.000",
        f"set sram{index}_port_clk [get_clocks -of_objects [get_ports port_clk]]",
        f"set_input_delay -clock $sram{index}_port_clk -max $sram{index}_input_delay_max_ns [get_ports [list {inputs}]]",
        f"set_input_delay -clock $sram{index}_port_clk -min $sram{index}_input_delay_min_ns [get_ports [list {inputs}]]",
        f"set_output_delay -clock $sram{index}_port_clk -max $sram{index}_output_delay_max_ns [get_ports [list {outputs}]]",
        f"set_output_delay -clock $sram{index}_port_clk -min $sram{index}_output_delay_min_ns [get_ports [list {outputs}]]",
        "",
    ]
    return "\n".join(lines)


def emit_strict_constraints(config: Config) -> OrderedDict[str, str]:
    return OrderedDict(
        (f"constraints/sram{index}_strict.xdc", emit_port_constraints(index))
        for index in range(config.port_count)
    )
