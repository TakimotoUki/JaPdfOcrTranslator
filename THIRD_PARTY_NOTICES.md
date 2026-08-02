# 第三方组件说明

本项目包含或依赖第三方开源软件与模型。各组件的著作权和许可条款归其各自作者所有。

## NDLOCR-Lite

- 项目：https://github.com/ndl-lab/ndlocr-lite
- 作者：国立国会图书馆 NDL Lab
- 许可：Creative Commons Attribution 4.0 International（CC BY 4.0）

本项目随应用分发 NDLOCR-Lite 的部分程序、配置和 ONNX 模型，用于日文版面检测、文字识别与阅读顺序恢复。使用、修改或再分发相关内容时，请遵守原项目的署名要求及其依赖组件的许可条款。

## 其他组件

运行过程中还会使用或安装以下第三方组件：

- PARSeq
- DEIM
- ONNX Runtime
- OpenCV
- NumPy
- Pillow
- PyYAML
- NetworkX
- lxml
- pypdfium2
- pypdf
- ReportLab

具体版本与依赖范围以 `Sources/JaPdfOcrTranslator/Resources/requirements.txt` 为准。请在再分发前核对对应版本附带的许可证文本。

