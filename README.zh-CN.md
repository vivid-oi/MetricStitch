# MetricStitch

MoonBit 增量指标累积、检查点恢复与有界乱序处理库，采用 Apache-2.0。
适合遥测网关、本地指标代理和离线 OTLP 排障工具开发者。

## 快速运行

仓库验证工具链为 `moonc 0.10.19+bee578715`。从仓库根目录运行：

```sh
moon update
moon run --target wasm examples/counter
moon run --target wasm examples/reorder
moon run --target wasm cli -- replay-to examples/session.json session-receipt.json
moon run --target wasm cli -- inspect session-receipt.json
moon run --target wasm cli -- export session-receipt.json session-otlp.json
```

输出文件必须尚不存在。示例包含连续两段 Counter、Gauge、显式桶 Histogram；
第二段 Counter 累积为 7.5、Histogram 数量为 4、Gauge 为 11。
样例由官方 OTLP 示例改编，数值与区间为演示数据，来源见 [SOURCES](SOURCES.md)。

## 接入自己的 MoonBit 模块

当前源码版本为 **0.2.0**，不代表已发布至 Mooncakes。可先用 `moon.work`
同时列入本库与自己的模块，在自己模块的 `moon.mod` 声明
`"vivid-oi/metricstitch@0.2.0"`，`moon.pkg` 导入 `"vivid-oi/metricstitch"`。
现成独立模块演示：

```sh
moon -C integration run --target wasm consumer
moon run checks/package.mbtx
```

第二条会打包、审查归档内容，在临时目录解包后运行测试并供独立模块使用，
不会发布到注册表。外部依赖首次解析需要网络；Unix 环境需要 `unzip`，
Windows 使用系统 `tar`。完整类型和方法见 [公开接口](pkg.generated.mbti)。

## 能力与边界

| 已实现能力 | 明确限制 |
|---|---|
| 非负 Int64／有限非负 Double 单调 Sum 累积 | 不接受负增量或同序列数值种类切换 |
| 显式桶 Histogram 累积，Gauge 校验透传 | 不支持指数直方图；不静默丢弃未知字段 |
| 原子请求与序列回放、检查点、回执、安全文件输出 | 单写者顺序由调用方保证；不保证恰好一次交付 |
| 稳定错误码与带索引的诊断路径 | `check` 返回第一项语义错误；语法和 I/O 错误走 stderr |
| 类型化点的有界乱序缓冲与完整待处理点恢复 | 调用方推进 watermark；OTLP 请求入口仍严格按序 |
| 状态统计与显式归档 | 调用方负责持久化、归档路由和送达确认 |

核心支持 Wasm、Wasm-GC、JavaScript、Native；异步 CLI 支持 Wasm、Native。
CI 在 Linux、macOS、Windows 实际运行原生测试、示例和回放。

## 进一步验证

- [真实 Collector 接入与独立消费模块](docs/collector.md)：固定 0.166.0，
  仅回环网络，无需私有监控平台。
- [乱序处理契约与恢复流程](docs/reordering.md)：容量、窗口、冲突、失败回滚。
- [规模与基准方法](docs/performance.md)：记录实测条件和剩余复制成本。
- [兼容性与发布步骤](docs/release.md)：接口、检查点与打包验证范围。

网络接收、多写者协调、指数直方图尚未实现，见 [英文说明](README.md)。
