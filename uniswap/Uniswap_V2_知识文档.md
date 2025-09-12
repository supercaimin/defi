# Uniswap V2 核心知识文档

## 目录
1. [Uniswap V2 架构概述](#1-uniswap-v2-架构概述)
2. [核心合约分析](#2-核心合约分析)
3. [AMM 机制详解](#3-amm-机制详解)
4. [滑点计算](#4-滑点计算)
5. [无常损失 (Impermanent Loss)](#5-无常损失-impermanent-loss)
6. [价格预言机](#6-价格预言机)
7. [手续费机制](#7-手续费机制)
8. [流动性挖矿](#8-流动性挖矿)
9. [安全机制](#9-安全机制)
10. [代码实现细节](#10-代码实现细节)

---

## 1. Uniswap V2 架构概述

### 1.1 核心组件
Uniswap V2 是一个去中心化交易所(DEX)，基于自动做市商(AMM)模型，主要包含以下核心合约：

- **UniswapV2Factory**: 工厂合约，负责创建和管理交易对
- **UniswapV2Pair**: 交易对合约，管理具体的代币交易对
- **UniswapV2ERC20**: LP代币合约，代表流动性提供者的份额

### 1.2 架构特点
```
┌─────────────────────────────────────────────────────────────┐
│                    Uniswap V2 架构                          │
├─────────────────────────────────────────────────────────────┤
│  Core Contracts (v2-core)                                  │
│  ├── UniswapV2Factory                                      │
│  │   ├── 交易对创建管理                                       │
│  │   ├── 手续费设置 (feeTo, feeToSetter)                    │
│  │   ├── 交易对地址映射 (getPair)                           │
│  │   └── 所有交易对列表 (allPairs)                          │
│  ├── UniswapV2Pair (每个交易对独立合约)                      │
│  │   ├── 恒定乘积公式 (x * y = k)                           │
│  │   ├── 流动性管理 (mint/burn)                             │
│  │   ├── 代币交换 (swap)                                    │
│  │   ├── 价格预言机数据 (TWAP)                              │
│  │   └── 手续费铸造机制                                      │
│  └── UniswapV2ERC20                                        │
│      ├── ERC20 标准实现                                     │
│      ├── EIP-712 签名授权 (permit)                          │
│      └── LP代币管理                                         │
├─────────────────────────────────────────────────────────────┤
│  Math Libraries                                             │
│  ├── Math                                                   │
│  │   ├── min() 函数                                         │
│  │   └── sqrt() 函数 (Babylonian方法)                       │
│  ├── UQ112x112                                             │
│  │   ├── 二进制定点数处理                                    │
│  │   └── Q112.112 格式转换                                  │
│  └── SafeMath                                              │
│      └── 安全数学运算                                        │
├─────────────────────────────────────────────────────────────┤
│  AMM 机制                                                   │
│  ├── 恒定乘积公式                                           │
│  │   ├── x * y = k (k为常数)                               │
│  │   ├── 价格 = y / x                                      │
│  │   └── 滑点计算                                           │
│  ├── 流动性提供                                             │
│  │   ├── 按比例添加代币                                     │
│  │   ├── 铸造LP代币                                         │
│  │   └── 手续费分配                                         │
│  └── 价格预言机                                             │
│      ├── TWAP 计算                                          │
│      ├── 价格累积值                                         │
│      └── 时间加权平均价格                                    │
├─────────────────────────────────────────────────────────────┤
│  Security Features                                          │
│  ├── 重入攻击保护 (lock modifier)                           │
│  ├── 最小流动性要求 (MINIMUM_LIQUIDITY)                     │
│  ├── 价格操纵保护                                           │
│  └── 手续费机制                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 工作原理
Uniswap V2 使用恒定乘积公式 `x * y = k` 来确定代币价格，其中：
- `x` 和 `y` 是交易对中两种代币的储备量
- `k` 是常数，在交易过程中保持不变

### 1.4 合约交互流程
```
┌─────────────────────────────────────────────────────────────┐
│                Uniswap V2 合约交互流程                       │
├─────────────────────────────────────────────────────────────┤
│  交易对创建流程                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   用户      │    │   Factory   │    │    Pair     │     │
│  │             │    │             │    │             │     │
│  └─────┬───────┘    └─────┬───────┘    └─────┬───────┘     │
│        │                  │                  │             │
│        │ 1. 创建交易对     │                  │             │
│        ├─────────────────►│                  │             │
│        │                  │ 2. 验证代币地址   │             │
│        │                  │ 3. 检查是否存在   │             │
│        │                  │ 4. 部署Pair合约   │             │
│        │                  ├─────────────────►│             │
│        │                  │                  │ 5. 初始化   │
│        │                  │ 6. 更新映射      │             │
│        │                  │ 7. 返回地址      │             │
│        │◄─────────────────┤◄─────────────────┤             │
│        │                  │                  │             │
├─────────────────────────────────────────────────────────────┤
│  代币交换流程                                                │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   用户      │    │    Pair     │    │   TokenA    │     │
│  │             │    │             │    │   TokenB    │     │
│  └─────┬───────┘    └─────┬───────┘    └─────┬───────┘     │
│        │                  │                  │             │
│        │ 1. 请求交换       │                  │             │
│        ├─────────────────►│                  │             │
│        │                  │ 2. 计算输出量     │             │
│        │                  │ 3. 验证k值        │             │
│        │                  │ 4. 更新储备量     │             │
│        │                  │ 5. 转账代币       │             │
│        │                  ├─────────────────►│             │
│        │                  │ 6. 更新价格       │             │
│        │                  │ 7. 返回结果      │             │
│        │◄─────────────────┤                  │             │
│        │                  │                  │             │
├─────────────────────────────────────────────────────────────┤
│  流动性管理流程                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   用户      │    │    Pair     │    │   TokenA    │     │
│  │             │    │             │    │   TokenB    │     │
│  └─────┬───────┘    └─────┬───────┘    └─────┬───────┘     │
│        │                  │                  │             │
│        │ 1. 添加流动性     │                  │             │
│        ├─────────────────►│                  │             │
│        │                  │ 2. 计算LP代币量   │             │
│        │                  │ 3. 铸造LP代币     │             │
│        │                  │ 4. 更新储备量     │             │
│        │                  │ 5. 转账代币       │             │
│        │                  ├─────────────────►│             │
│        │                  │ 6. 更新价格       │             │
│        │                  │ 7. 返回LP代币     │             │
│        │◄─────────────────┤                  │             │
│        │                  │                  │             │
├─────────────────────────────────────────────────────────────┤
│  价格预言机流程                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   用户      │    │    Pair     │    │   Oracle    │     │
│  │             │    │             │    │             │     │
│  └─────┬───────┘    └─────┬───────┘    └─────┬───────┘     │
│        │                  │                  │             │
│        │ 1. 查询价格       │                  │             │
│        ├─────────────────►│                  │             │
│        │                  │ 2. 读取累积价格   │             │
│        │                  │ 3. 计算TWAP      │             │
│        │                  ├─────────────────►│             │
│        │                  │                  │ 4. 返回数据 │
│        │                  │ 5. 返回TWAP      │             │
│        │◄─────────────────┤                  │             │
│        │                  │                  │             │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 核心合约分析

### 2.1 UniswapV2Factory 合约

#### 主要功能
```solidity
contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;           // 手续费接收地址
    address public feeToSetter;     // 手续费设置者
    
    // 交易对映射: tokenA => tokenB => pairAddress
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;      // 所有交易对列表
}
```

#### 关键方法
- `createPair(address tokenA, address tokenB)`: 创建新的交易对
- `setFeeTo(address _feeTo)`: 设置手续费接收地址
- `allPairsLength()`: 获取交易对总数

#### 交易对创建流程
1. 验证代币地址有效性
2. 对代币地址排序（token0 < token1）
3. 检查交易对是否已存在
4. 使用 CREATE2 部署新交易对合约
5. 初始化交易对并更新映射

### 2.2 UniswapV2Pair 合约

#### 核心状态变量
```solidity
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    uint public constant MINIMUM_LIQUIDITY = 10**3;  // 最小流动性
    
    address public factory;         // 工厂合约地址
    address public token0;          // 代币0地址
    address public token1;          // 代币1地址
    
    uint112 private reserve0;       // 代币0储备量
    uint112 private reserve1;       // 代币1储备量
    uint32  private blockTimestampLast; // 最后更新时间戳
    
    uint public price0CumulativeLast; // 代币0价格累积值
    uint public price1CumulativeLast; // 代币1价格累积值
    uint public kLast;              // 上次流动性事件后的k值
}
```

#### 主要功能
1. **添加流动性 (mint)**
2. **移除流动性 (burn)**
3. **代币交换 (swap)**
4. **价格更新 (_update)**
5. **手续费铸造 (_mintFee)**

### 2.3 UniswapV2ERC20 合约

#### 功能特点
- 实现 ERC20 标准
- 支持 EIP-712 签名授权 (permit)
- 代表流动性提供者的份额

---

## 3. AMM 机制详解

### 3.1 AMM 机制架构
```
┌─────────────────────────────────────────────────────────────┐
│                    AMM 机制架构                             │
├─────────────────────────────────────────────────────────────┤
│  恒定乘积公式 (x * y = k)                                   │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  代币A储备量 (x)    │    代币B储备量 (y)    │    k值     │ │
│  │  1000 USDC         │    0.5 ETH           │   500      │ │
│  │  价格 = y/x = 0.5/1000 = 0.0005 ETH/USDC               │ │
│  └─────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  价格计算机制                                                │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   输入      │    │   计算      │    │   输出      │     │
│  │  代币A数量   │───►│ 恒定乘积公式 │───►│  代币B数量   │     │
│  │  代币B数量   │    │ x * y = k  │    │  价格       │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
├─────────────────────────────────────────────────────────────┤
│  滑点计算机制                                                │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  滑点 = (预期价格 - 实际价格) / 预期价格 * 100%          │ │
│  │                                                         │ │
│  │  示例: 用100 USDC购买ETH                                │ │
│  │  预期价格: 0.0005 ETH/USDC                              │ │
│  │  实际价格: 0.000495 ETH/USDC                            │ │
│  │  滑点: (0.0005 - 0.000495) / 0.0005 * 100% = 1%        │ │
│  └─────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  流动性提供机制                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   用户      │    │   计算      │    │   LP代币    │     │
│  │  代币A数量   │───►│  LP代币量   │───►│   铸造      │     │
│  │  代币B数量   │    │ 按比例计算  │    │   分配      │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
├─────────────────────────────────────────────────────────────┤
│  手续费机制                                                  │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  交易手续费: 0.3% (每笔交易)                            │ │
│  │  协议手续费: 0.05% (可配置)                             │ │
│  │  LP手续费: 0.25% (分配给流动性提供者)                   │ │
│  │                                                         │ │
│  │  手续费分配:                                            │ │
│  │  ├── 流动性提供者: 0.25%                               │ │
│  │  ├── 协议费用: 0.05% (可选)                            │ │
│  │  └── 总手续费: 0.3%                                    │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 价格曲线可视化
```
┌─────────────────────────────────────────────────────────────┐
│                价格曲线 (x * y = k)                         │
├─────────────────────────────────────────────────────────────┤
│  价格 (y/x)                                                 │
│      │                                                      │
│      │  ╭─╮                                                 │
│      │ ╱   ╲                                                │
│      │╱     ╲                                               │
│      │       ╲                                              │
│      │        ╲                                             │
│      │         ╲                                            │
│      │          ╲                                           │
│      │           ╲                                          │
│      │            ╲                                         │
│      │             ╲                                        │
│      │              ╲                                       │
│      │               ╲                                      │
│      │                ╲                                     │
│      │                 ╲                                    │
│      │                  ╲                                   │
│      │                   ╲                                  │
│      │                    ╲                                 │
│      │                     ╲                                │
│      │                      ╲                               │
│      │                       ╲                              │
│      │                        ╲                             │
│      │                         ╲                            │
│      │                          ╲                           │
│      │                           ╲                          │
│      │                            ╲                         │
│      │                             ╲                        │
│      │                              ╲                       │
│      │                               ╲                      │
│      │                                ╲                     │
│      │                                 ╲                    │
│      │                                  ╲                   │
│      │                                   ╲                  │
│      │                                    ╲                 │
│      │                                     ╲                │
│      │                                      ╲               │
│      │                                       ╲              │
│      │                                        ╲             │
│      │                                         ╲            │
│      │                                          ╲           │
│      │                                           ╲          │
│      │                                            ╲         │
│      │                                             ╲        │
│      │                                              ╲       │
│      │                                               ╲      │
│      │                                                ╲     │
│      │                                                 ╲    │
│      │                                                  ╲   │
│      │                                                   ╲  │
│      │                                                    ╲ │
│      │                                                     ╲│
│      └──────────────────────────────────────────────────────┼
│                                                             │
│  0 ─────────────────────────────────────────────────────────┼── 储备量 (x)
│                                                             │
│  特点:                                                      │
│  - 价格与储备量成反比                                       │
│  - 大额交易会产生滑点                                       │
│  - 流动性越高，滑点越小                                     │
└─────────────────────────────────────────────────────────────┘
```

### 3.1 恒定乘积公式

Uniswap V2 使用恒定乘积公式：
```
x * y = k
```

其中：
- `x` = 代币0的储备量
- `y` = 代币1的储备量  
- `k` = 常数（在交易过程中保持不变）

### 3.2 价格计算

代币价格由储备量比例决定：
```
价格 = y / x
```

例如：如果 ETH/USDC 交易对中有 1000 ETH 和 2,000,000 USDC，则：
- ETH 价格 = 2,000,000 / 1000 = 2000 USDC

### 3.3 交易计算

当用户用 `Δx` 数量的代币0换取代币1时，根据恒定乘积公式：

```
(x + Δx) * (y - Δy) = x * y
```

解得：
```
Δy = (y * Δx) / (x + Δx)
```

考虑手续费（0.3%）：
```
Δy = (y * Δx * 997) / (x * 1000 + Δx * 997)
```

---

## 4. 滑点计算

### 4.1 滑点定义
滑点是指实际成交价格与预期价格之间的差异，通常以百分比表示。

### 4.2 滑点计算公式

#### 理论价格（无滑点）
```
理论价格 = y / x
```

#### 实际价格（有滑点）
```
实际价格 = Δy / Δx
```

#### 滑点百分比
```
滑点 = (实际价格 - 理论价格) / 理论价格 × 100%
```

### 4.3 滑点影响因素

1. **交易规模**: 交易量越大，滑点越大
2. **流动性深度**: 流动性越少，滑点越大
3. **价格冲击**: 大额交易会显著影响价格

### 4.4 滑点计算示例

假设 ETH/USDC 交易对：
- 储备量：1000 ETH, 2,000,000 USDC
- 用户想用 100 ETH 换取 USDC

**理论价格**: 2000 USDC/ETH

**实际计算**:
```
Δy = (2,000,000 × 100 × 997) / (1000 × 1000 + 100 × 997)
   = 199,400,000 / 1,099,700
   = 181,140 USDC
```

**实际价格**: 181,140 / 100 = 1,811.4 USDC/ETH

**滑点**: (2000 - 1811.4) / 2000 × 100% = 9.43%

---

## 5. 无常损失 (Impermanent Loss)

### 5.1 定义
无常损失是指流动性提供者(LP)在提供流动性期间，由于代币价格变化导致的损失。这种损失只有在LP退出流动性时才会"实现"。

### 5.2 无常损失计算公式

假设：
- 初始价格比例：P₀ = y₀/x₀
- 当前价格比例：P₁ = y₁/x₁
- 价格变化率：r = P₁/P₀

无常损失百分比：
```
IL = 2√r / (1 + r) - 1
```

### 5.3 不同价格变化下的无常损失

| 价格变化 | 无常损失 |
|---------|---------|
| 1.25x   | 0.6%    |
| 1.5x    | 2.0%    |
| 2x      | 5.7%    |
| 3x      | 13.4%   |
| 4x      | 20.0%   |
| 5x      | 25.5%   |
| 10x     | 41.4%   |

### 5.4 无常损失示例

假设提供 ETH/USDC 流动性：
- 初始：1 ETH = 2000 USDC
- 提供：1 ETH + 2000 USDC
- 价格变化：1 ETH = 4000 USDC

**计算过程**:
1. 初始价格比例：P₀ = 2000
2. 当前价格比例：P₁ = 4000  
3. 价格变化率：r = 4000/2000 = 2
4. 无常损失：IL = 2√2/(1+2) - 1 = 2.828/3 - 1 = -0.057 = -5.7%

**结果**:
- 如果持有代币：1 ETH + 2000 USDC = 6000 USDC
- 作为LP：约 5657 USDC
- 损失：约 343 USDC (5.7%)

---

## 6. 价格预言机

### 6.1 时间加权平均价格 (TWAP)

Uniswap V2 实现了简单的时间加权平均价格机制：

```solidity
// 价格累积值更新
price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
```

### 6.2 TWAP 计算

```
TWAP = (priceCumulativeCurrent - priceCumulativeOld) / timeElapsed
```

### 6.3 价格预言机优势

1. **抗操纵**: 需要大量资金才能显著影响价格
2. **去中心化**: 不依赖中心化数据源
3. **实时更新**: 每次交易都会更新价格

### 6.4 使用示例

```solidity
// 获取过去1小时的TWAP
uint32 timeElapsed = blockTimestamp - blockTimestampOld;
uint price0TWAP = (price0Cumulative - price0CumulativeOld) / timeElapsed;
```

---

## 7. 手续费机制

### 7.1 手续费结构

Uniswap V2 的手续费为 **0.3%**，分配如下：
- **0.25%**: 给流动性提供者
- **0.05%**: 给协议（如果启用）

### 7.2 手续费计算

在交易中，手续费通过调整后的余额计算：
```solidity
uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
```

### 7.3 协议手续费

协议手续费通过 `_mintFee` 函数实现：
```solidity
function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
    address feeTo = IUniswapV2Factory(factory).feeTo();
    feeOn = feeTo != address(0);
    if (feeOn) {
        uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
        uint rootKLast = Math.sqrt(_kLast);
        if (rootK > rootKLast) {
            uint numerator = totalSupply.mul(rootK.sub(rootKLast));
            uint denominator = rootK.mul(5).add(rootKLast);
            uint liquidity = numerator / denominator;
            if (liquidity > 0) _mint(feeTo, liquidity);
        }
    }
}
```

---

## 8. 流动性挖矿

### 8.1 添加流动性 (Mint)

```solidity
function mint(address to) external lock returns (uint liquidity) {
    (uint112 _reserve0, uint112 _reserve1,) = getReserves();
    uint balance0 = IERC20(token0).balanceOf(address(this));
    uint balance1 = IERC20(token1).balanceOf(address(this));
    uint amount0 = balance0.sub(_reserve0);
    uint amount1 = balance1.sub(_reserve1);

    bool feeOn = _mintFee(_reserve0, _reserve1);
    uint _totalSupply = totalSupply;
    
    if (_totalSupply == 0) {
        // 首次添加流动性
        liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
        _mint(address(0), MINIMUM_LIQUIDITY); // 永久锁定
    } else {
        // 后续添加流动性
        liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, 
                           amount1.mul(_totalSupply) / _reserve1);
    }
    
    require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
    _mint(to, liquidity);
    _update(balance0, balance1, _reserve0, _reserve1);
}
```

### 8.2 移除流动性 (Burn)

```solidity
function burn(address to) external lock returns (uint amount0, uint amount1) {
    (uint112 _reserve0, uint112 _reserve1,) = getReserves();
    uint balance0 = IERC20(token0).balanceOf(address(this));
    uint balance1 = IERC20(token1).balanceOf(address(this));
    uint liquidity = balanceOf[address(this)];

    bool feeOn = _mintFee(_reserve0, _reserve1);
    uint _totalSupply = totalSupply;
    
    amount0 = liquidity.mul(balance0) / _totalSupply;
    amount1 = liquidity.mul(balance1) / _totalSupply;
    
    require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
    _burn(address(this), liquidity);
    _safeTransfer(token0, to, amount0);
    _safeTransfer(token1, to, amount1);
    _update(balance0, balance1, _reserve0, _reserve1);
}
```

---

## 9. 安全机制

### 9.1 重入攻击防护

使用 `lock` 修饰符防止重入攻击：
```solidity
uint private unlocked = 1;
modifier lock() {
    require(unlocked == 1, 'UniswapV2: LOCKED');
    unlocked = 0;
    _;
    unlocked = 1;
}
```

### 9.2 价格操纵防护

通过 K 值检查防止价格操纵：
```solidity
require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
```

### 9.3 最小流动性锁定

首次添加流动性时锁定最小流动性：
```solidity
if (_totalSupply == 0) {
    liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
    _mint(address(0), MINIMUM_LIQUIDITY); // 永久锁定
}
```

---

## 10. 代码实现细节

### 10.1 数学库

#### Math.sol - 数学运算
```solidity
library Math {
    function min(uint x, uint y) internal pure returns (uint z) {
        z = x < y ? x : y;
    }
    
    // 巴比伦方法计算平方根
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
```

#### UQ112x112.sol - 定点数运算
```solidity
library UQ112x112 {
    uint224 constant Q112 = 2**112;
    
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112;
    }
    
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}
```

### 10.2 关键算法

#### 价格更新算法
```solidity
function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
    require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
    uint32 blockTimestamp = uint32(block.timestamp % 2**32);
    uint32 timeElapsed = blockTimestamp - blockTimestampLast;
    
    if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
        price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
        price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
    }
    
    reserve0 = uint112(balance0);
    reserve1 = uint112(balance1);
    blockTimestampLast = blockTimestamp;
    emit Sync(reserve0, reserve1);
}
```

#### 交换算法
```solidity
function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
    require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
    (uint112 _reserve0, uint112 _reserve1,) = getReserves();
    require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');
    
    // 乐观转账
    if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
    if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);
    
    // 回调（用于闪电贷等）
    if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
    
    uint balance0 = IERC20(token0).balanceOf(address(this));
    uint balance1 = IERC20(token1).balanceOf(address(this));
    
    uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
    uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
    require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
    
    // K值检查
    uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
    uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
    require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
    
    _update(balance0, balance1, _reserve0, _reserve1);
    emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
}
```

---

## 总结

Uniswap V2 是一个创新的去中心化交易所，通过以下核心特性实现了高效、安全的代币交换：

1. **恒定乘积公式**: 确保流动性池的数学一致性
2. **自动做市商**: 无需传统订单簿，通过算法定价
3. **流动性挖矿**: 激励用户提供流动性
4. **价格预言机**: 提供可靠的价格数据
5. **安全机制**: 多重防护措施确保资金安全

理解这些核心概念对于参与 DeFi 生态系统和开发相关应用至关重要。滑点和无常损失是LP需要重点考虑的风险因素，而价格预言机则为其他DeFi协议提供了重要的基础设施。

---

*本文档基于 Uniswap V2 核心合约代码分析整理，涵盖了AMM机制、数学计算、安全机制等关键知识点。*
