# 唾液 → 尿液 跨体液多组学关联分析
**Saliva → Urine cross-body-fluid multi-omics integration**

在牙周炎–糖尿病–肾病共病队列中，系统评估**唾液（口腔）与尿液（系统/远端）**之间
**微生物组**与**代谢组**的跨体液关联，并筛选可用于动物实验验证的候选代谢物。
方法框架迁移自 **Zhang et al., *Microbiome* (2026) 14:147 —— *Cross-body site microbial
interactions influence the human plasma metabolome*** 的「口腔→肠道→血浆代谢物」跨体位轴。

> ⚠️ **数据可得性**：本仓库**只包含分析代码**。原始数据为人体临床队列（患者唾液/尿液样本 +
> 临床指标），出于隐私与伦理考虑**未纳入版本控制**（见 `.gitignore`）。复现需自行放置数据，见下文。

---

## 1. 研究设计

- **队列**：101 位受试者，每人同时采集唾液与尿液，各测微生物组 + 代谢组（四层数据完全配对）。
- **疾病分组**：N（正常）、P（牙周炎）、PD（+糖尿病）、PC（+肾病）、PCD（+糖尿病肾病）。
- **方向**：所有分析均为 **唾液（近端）→ 尿液（远端）**，三个模态配对：
  1. 微生物组 → 微生物组
  2. 微生物组 → 代谢组
  3. 代谢组 → 代谢组
  外加一条三层中介链（唾液菌 → 尿液菌 → 尿液代谢物）。

## 2. 分析流程

| 步骤 | 方法 | 实现 |
|---|---|---|
| 预处理 | 微生物组物种水平（流行度+丰度联合过滤 RA>0.01% & ≥5% 样本）；代谢组 pos+neg 合并、log2 | `crossomics_helpers.R` |
| 整体一致性 | **Mantel** + **Procrustes**（999 置换） | `congruence()` |
| 方差解释 | **PERMANOVA (adonis2)** 与 **dbRDA**（唾液主坐标轴约束） | `permanova_xy()` / `variance_explained()` |
| 逐特征 PERMANOVA | 每个唾液特征单独 adonis2 → R²（McArdle–Anderson，向量化） | `permanova_per_feature()` |
| 论文式累计方差 | 显著特征联合 adonis2 + 无放回再抽样 95% CI | `permanova_cumulative()` |
| 相关网络 | Spearman \|r\|≥0.3, P<0.05（+BH-FDR），igraph/ggraph | `cross_correlation()` / `plot_cross_network()` |
| 机器学习预测 | RandomForest 5 折交叉验证逐特征 R² | `rf_predict_R2()` |
| 中介分析 | `mediation::mediate`，校正年龄/性别/疾病组，FDR | `mediation_scan()` |
| 候选筛选 | 两部位共享 + 健康 vs 疾病均显著且同向（Wilcoxon+FDR） | `shared_disease_test()` |
| 亚组特异性 | P/PD/PC/PCD 各自 vs N；肾病梯度趋势（Jonckheere–Terpstra）+ 多变量校正 | `subgroup_screen()` / `kidney_trend_test()` |
| 候选分层 | 内源性/可购/已确证三档（优先/待确证/排除） | `classify_candidates()` |

## 3. 四套报告（数据库 × 样本集）

同一份参数化 Rmd 渲染出四个变体，用于**数据库交叉验证**和**敏感性分析**：

| 变体 | 微生物数据库 | 样本 | 输出目录 |
|---|---|---|---|
| GTDB 全样本 | GTDB | 101 | `GTDB_Results/` |
| HROM 全样本 | HROM | 101 | `HROM_Results/` |
| GTDB 排除PD | GTDB | 95（去 n=6 的 PD 组） | `GTDB_noPD_Results/` |
| HROM 排除PD | HROM | 95 | `HROM_noPD_Results/` |

每个目录含：`*.html` 报告、`crossomics/*.pptx`（19 页汇报 PPT）、`crossomics/tables/*.csv`、`crossomics/figures/*.png`。

## 4. 主要发现（结论对数据库与样本集均稳健）

- **代谢组 ↔ 代谢组是最强的跨体液轴**（Mantel r≈0.29–0.31, dbRDA R²≈0.17，均显著）。
- **微生物组跨体液耦合弱**（Mantel≈0），口腔与泌尿道是相对独立的微生态；三层中介不显著。
- **候选靶点 = 丙酸（Propionic acid）**：唾液与尿液同步下降、随**肾病严重度**单调下降
  （Jonckheere–Terpstra P<1e-8）、且**独立于牙周炎与糖尿病**（多变量校正 β≈−0.7~−1.0, P<0.001）。
  → 动物验证建议以 **CKD 为核心模型**、补充丙酸钠检验因果。

> ⚠️ 人群结果均为**关联性**（横断面）。本队列**无 eGFR/肌酐等连续肾功能指标**，
> 「肾病梯度」为有序严重度分级而非真实 eGFR。

---

## 5. 如何复现

### 5.1 环境

- **R ≥ 4.3**，包：`data.table vegan phyloseq compositions igraph ggraph ggplot2 rmarkdown knitr kableExtra dplyr tidyr randomForest glmnet mediation DescTools readxl ggrepel stringr`
- **pandoc**（`rmarkdown::render` 需要；若命令行找不到，`export RSTUDIO_PANDOC=<pandoc 目录>`）
- **中文/UTF-8**：命令行渲染前 `export LANG=en_US.UTF-8`（否则无法解析中文源码）。
  *注*：图内文字一律用英文——本机图形设备对中日韩字体会崩溃，Rmd 已按此约定处理。
- **PPT 构建**：Python + `python-pptx`、`Pillow`；PPT 用 **PingFang SC** 字体（macOS）。

### 5.2 放置数据

复现需在 `Data/` 下提供（结构见 Rmd 顶部 `params` 与 `load-data` chunk）：
```
Data/microbiome_data/{Saliva,Urine}_{GTDB,HROM}_abd.txt   # 物种×样本 相对丰度
Data/microbiome_data/Saliva_meta.txt                      # 样本分组/年龄/性别
Data/metabolome_data/{pos,neg}_{saliva,urin}_renamed.csv  # 代谢物ID×样本
Data/PKU-101-微生物-代谢物数据/{pos,neg}_{saliva,urin}.xlsx # Sheet3 = ID→Metabolite name
```

### 5.3 运行

```bash
export LANG=en_US.UTF-8
export RSTUDIO_PANDOC=/path/to/pandoc      # 例：RStudio 自带的 quarto/bin/tools/<arch>

# ① 代谢物 ID → 名称 并合并同名列（生成 *_named.csv，必须先跑）
Rscript Scripts/rename_merge_metabolites.R

# ② 渲染四套报告（参数化同一 Rmd；drop_groups=character(0) 为全样本）
render () {   # db  saliva_file  urine_file  outdir  drop
  Rscript -e "rmarkdown::render('Scripts/GTDB_cross_site_multiomics.Rmd',
    encoding='UTF-8', knit_root_dir=normalizePath('.'),
    output_dir='$4', output_file='$(basename $4)_cross_site_multiomics.html',
    params=list(db='$1', saliva_mic='Data/microbiome_data/$2',
                urine_mic='Data/microbiome_data/$3',
                outdir='$4/crossomics', drop_groups=$5))"
}
render GTDB Saliva_GTDB_abd.txt Urine_GTDB_abd.txt GTDB_Results      "character(0)"
render HROM Saliva_HROM_abd.txt Urine_HROM_abd.txt HROM_Results      "character(0)"
render GTDB Saliva_GTDB_abd.txt Urine_GTDB_abd.txt GTDB_noPD_Results "'PD'"
render HROM Saliva_HROM_abd.txt Urine_HROM_abd.txt HROM_noPD_Results "'PD'"

# ③ 构建 PPT（读取各自 tables/*.csv，与报告自动同步）
python Scripts/build_crossomics_ppt.py GTDB
python Scripts/build_crossomics_ppt.py HROM
python Scripts/build_crossomics_ppt.py GTDB_noPD
python Scripts/build_crossomics_ppt.py HROM_noPD
```

单个变体约 4–7 分钟（RandomForest 为主要耗时）。缓存已禁用以保证结果正确。

## 6. 仓库结构

```
Scripts/
  crossomics_helpers.R              # 全部分析与绘图函数
  GTDB_cross_site_multiomics.Rmd    # 参数化主报告（db / 样本子集 均由 params 控制）
  rename_merge_metabolites.R        # 代谢物 ID→名称、合并同名
  build_crossomics_ppt.py           # 生成 19 页汇报 PPT
Data/                               # 患者数据（gitignored）
{GTDB,HROM}[_noPD]_Results/         # 生成的报告/PPT/表/图（gitignored）
```
> 注：`Scripts/` 内另有 `*_group_comparison.Rmd`、`build_db_comparison_ppt.py` 等，
> 属于早期「GTDB vs HROM 数据库对比」子项目，与本跨体液流程独立。

## 7. 参考

Zhang J, Jiang C, Zhou X, Gao P, Wong S, Snyder M, Shen X.
*Cross-body site microbial interactions influence the human plasma metabolome.*
**Microbiome** 2026;14:147. PMID: 41952172.
