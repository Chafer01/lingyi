"""生成公式识别实测用的测试图（模仿学位论文 / 期刊排版：宋体正文、Times 风格公式、公式编号）。

    python tools/ocr_eval/make_fixtures.py

输出 tools/ocr_eval/fixtures/*.png 和 truth.json。需要 matplotlib 与 Noto Serif CJK 字体。
"""
from __future__ import annotations

import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager  # noqa: E402

OUT = Path(__file__).resolve().parent / "fixtures"
CJK = "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc"

font_manager.fontManager.addfont(CJK)
CJK_NAME = font_manager.FontProperties(fname=CJK).get_name()
plt.rcParams.update({
    "font.family": [CJK_NAME],
    "mathtext.fontset": "stix",
    "axes.unicode_minus": False,
})

# 每张图：若干行，每行 (文字, 字号, 对齐, 公式编号)；文字里用 $...$ 写公式（matplotlib mathtext）。
FIXTURES = {
    "thesis_abg": {
        "lines": [
            ("　　等效媒质理论适用于打孔结构的超材料，只要将高介电常数的基底介质与低介电常数", 15, "left", None),
            ("的插入介质混合，便能够得到等效介电常数介于二者之间的超材料。而二者混合的比例", 15, "left", None),
            ("由基底材料的介电常数、插入材料的介电常数和整体的等效介电常数计算得出。等效媒", 15, "left", None),
            ("质的计算公式有很多种，其中最为准确的是 A-BG 等效媒质理论：", 15, "left", None),
            (r"$\dfrac{\varepsilon_i-\varepsilon_{eff}}{\varepsilon_i-\varepsilon_h}=(1-p)"
             r"\left(\dfrac{\varepsilon_{eff}}{\varepsilon_h}\right)^{\frac{1}{3}}$", 17, "center", "(2-32)"),
            (r"　　其中 $\varepsilon_h$ 是基底材料介电常数，$\varepsilon_i$ 是插入材料介电常数，"
             r"$\varepsilon_{eff}$ 是等效介电常数，", 15, "left", None),
            (r"$p$ 是插入材料的体积分数。", 15, "left", None),
        ],
        "truth": {
            "text": "等效媒质理论适用于打孔结构的超材料，只要将高介电常数的基底介质与低介电常数的插入介质混合，"
                    "便能够得到等效介电常数介于二者之间的超材料。而二者混合的比例由基底材料的介电常数、插入材料的介电常数"
                    "和整体的等效介电常数计算得出。等效媒质的计算公式有很多种，其中最为准确的是A-BG等效媒质理论："
                    "其中是基底材料介电常数，是插入材料介电常数，是等效介电常数，是插入材料的体积分数。",
            "formulas": [r"\frac{\varepsilon_i-\varepsilon_{eff}}{\varepsilon_i-\varepsilon_h}=(1-p)"
                         r"\left(\frac{\varepsilon_{eff}}{\varepsilon_h}\right)^{\frac{1}{3}}"],
            "inline": [r"\varepsilon_h", r"\varepsilon_i", r"\varepsilon_{eff}", "p"],
            "number": "2-32",
        },
    },
    "array_factor_en": {
        "lines": [
            ("For a uniform linear array of N isotropic elements with spacing d and progressive", 15, "left", None),
            (r"phase $\beta$, the array factor is", 15, "left", None),
            (r"$AF(\theta)=\sum_{n=1}^{N}e^{j(n-1)(kd\cos\theta+\beta)}$", 17, "center", "(4)"),
            (r"The first grating lobe enters visible space when $d/\lambda>1/(1+|\cos\theta_0|)$,", 15, "left", None),
            (r"where $\theta_0$ is the scan angle measured from broadside.", 15, "left", None),
        ],
        "truth": {
            "text": "For a uniform linear array of N isotropic elements with spacing d and progressive phase , "
                    "the array factor is The first grating lobe enters visible space when , "
                    "where is the scan angle measured from broadside.",
            "formulas": [r"AF(\theta)=\sum_{n=1}^{N}e^{j(n-1)(kd\cos\theta+\beta)}"],
            "inline": [r"\beta", r"d/\lambda>1/(1+|\cos\theta_0|)", r"\theta_0"],
            "number": "4",
        },
    },
    "vswr_cn": {
        "lines": [
            ("　　端口反射系数与电压驻波比、回波损耗之间满足", 15, "left", None),
            (r"$\mathrm{VSWR}=\dfrac{1+|\Gamma|}{1-|\Gamma|},\quad RL=-20\log_{10}|\Gamma|$", 17, "center", "(3-5)"),
            (r"　　当回波损耗为 15 dB 时，$|\Gamma|\approx 0.178$，对应的电压驻波比约为 1.43。", 15, "left", None),
        ],
        "truth": {
            "text": "端口反射系数与电压驻波比、回波损耗之间满足当回波损耗为15dB时，，对应的电压驻波比约为1.43。",
            "formulas": [r"\mathrm{VSWR}=\frac{1+|\Gamma|}{1-|\Gamma|},\quad RL=-20\log_{10}|\Gamma|"],
            "inline": [r"|\Gamma|\approx0.178"],
            "number": "3-5",
        },
    },
    "microstrip_cn": {
        "lines": [
            ("　　微带线的有效介电常数可用下式近似计算：", 15, "left", None),
            (r"$\varepsilon_{eff}=\dfrac{\varepsilon_r+1}{2}+\dfrac{\varepsilon_r-1}{2}"
             r"\left(1+12\dfrac{h}{W}\right)^{-1/2}$", 17, "center", "(2-7)"),
            (r"　　式中 $h$ 为介质基板厚度，$W$ 为导带宽度，$\varepsilon_r$ 为基板相对介电常数。", 15, "left", None),
        ],
        "truth": {
            "text": "微带线的有效介电常数可用下式近似计算：式中为介质基板厚度，为导带宽度，为基板相对介电常数。",
            "formulas": [r"\varepsilon_{eff}=\frac{\varepsilon_r+1}{2}+\frac{\varepsilon_r-1}{2}"
                         r"\left(1+12\frac{h}{W}\right)^{-1/2}"],
            "inline": ["h", "W", r"\varepsilon_r"],
            "number": "2-7",
        },
    },
    "friis_only": {
        "lines": [
            (r"$P_r=P_tG_tG_r\left(\dfrac{\lambda}{4\pi R}\right)^2$", 20, "center", None),
        ],
        "truth": {
            "text": "",
            "formulas": [r"P_r=P_tG_tG_r\left(\frac{\lambda}{4\pi R}\right)^2"],
            "inline": [],
            "number": None,
        },
    },
}


def render(name: str, spec: dict):
    lines = spec["lines"]
    width_in = 9.0
    heights = [0.62 if align == "center" else 0.40 for _, _, align, _ in lines]
    fig = plt.figure(figsize=(width_in, sum(heights) + 0.35), dpi=110)
    fig.patch.set_facecolor("white")
    total = sum(heights) + 0.35
    y = total - 0.2
    for (text, size, align, number), h in zip(lines, heights):
        y -= h / 2
        if align == "center":
            fig.text(0.5, y / total, text, fontsize=size, ha="center", va="center")
        else:
            fig.text(0.04, y / total, text, fontsize=size, ha="left", va="center")
        if number:
            fig.text(0.96, y / total, number, fontsize=size - 1, ha="right", va="center",
                     fontfamily="STIXGeneral")
        y -= h / 2
    OUT.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT / f"{name}.png", facecolor="white")
    plt.close(fig)


def main():
    truth = {}
    for name, spec in FIXTURES.items():
        render(name, spec)
        truth[name] = spec["truth"]
    (OUT / "truth.json").write_text(json.dumps(truth, ensure_ascii=False, indent=1), encoding="utf-8")
    print("生成：", ", ".join(FIXTURES))


if __name__ == "__main__":
    main()
