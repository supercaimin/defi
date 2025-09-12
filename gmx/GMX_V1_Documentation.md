# GMX V1 项目文档

## 项目介绍

GMX V1 是一个去中心化的永续合约交易协议，基于 Arbitrum 和 Avalanche 网络构建。该协议允许用户以高达 50 倍杠杆进行加密货币的永续合约交易，同时为流动性提供者提供收益机会。

### 核心特性

- **永续合约交易**: 支持高达 50 倍杠杆的加密货币永续合约交易
- **去中心化价格预言机**: 使用 Chainlink 和 Band Protocol 等去中心化预言机获取价格数据
- **流动性挖矿**: 通过 GLP (GMX Liquidity Provider) 代币为流动性提供者提供收益
- **低滑点交易**: 通过优化的 AMM 机制减少交易滑点
- **多链支持**: 支持 Arbitrum 和 Avalanche 网络

## 架构设计

### 系统架构图

```mermaid
graph TB
    %% 用户层
    subgraph "用户层 (User Layer)"
        U1[交易者]
        U2[流动性提供者]
        U3[清算者]
    end

    %% 接口层
    subgraph "接口层 (Interface Layer)"
        PM[PositionManager<br/>仓位管理]
        R[Router<br/>代币路由]
        OB[OrderBook<br/>订单簿]
    end

    %% 核心层
    subgraph "核心层 (Core Layer)"
        V[Vault<br/>核心金库]
        ST[ShortsTracker<br/>空头跟踪]
        VR[VaultReader<br/>金库读取器]
    end

    %% 预言机层
    subgraph "预言机层 (Oracle Layer)"
        VPF[VaultPriceFeed<br/>金库价格预言机]
        FPF[FastPriceFeed<br/>快速价格预言机]
        PF[PriceFeed<br/>价格预言机]
        CL[Chainlink]
        BP[Band Protocol]
    end

    %% 代币层
    subgraph "代币层 (Token Layer)"
        GMX[GMX Token<br/>治理代币]
        GLP[GLP Token<br/>流动性代币]
        USDG[USDG Token<br/>稳定币]
        WETH[WETH]
    end

    %% 金库层
    subgraph "金库层 (Vault Layer)"
        V_BTC[BTC 金库]
        V_ETH[ETH 金库]
        V_USDC[USDC 金库]
        V_OTHER[其他代币金库]
    end

    %% 治理层
    subgraph "治理层 (Governance Layer)"
        GOV[Governable<br/>治理合约]
        TIMELOCK[Timelock<br/>时间锁]
        TR[TokenManager<br/>代币管理]
    end

    %% 连接关系
    U1 --> PM
    U2 --> V
    U3 --> PM

    PM --> V
    PM --> R
    PM --> OB

    R --> V
    OB --> V

    V --> VPF
    V --> ST
    V --> VR

    VPF --> FPF
    VPF --> PF
    FPF --> CL
    FPF --> BP

    V --> V_BTC
    V --> V_ETH
    V --> V_USDC
    V --> V_OTHER

    V --> GLP
    V --> USDG
    PM --> WETH

    V --> GOV
    GOV --> TIMELOCK
    GOV --> TR

    %% 样式
    classDef userLayer fill:#e1f5fe
    classDef interfaceLayer fill:#f3e5f5
    classDef coreLayer fill:#e8f5e8
    classDef oracleLayer fill:#e0f2f1
    classDef tokenLayer fill:#fff3e0
    classDef vaultLayer fill:#f9fbe7
    classDef governanceLayer fill:#fafafa

    class U1,U2,U3 userLayer
    class PM,R,OB interfaceLayer
    class V,ST,VR coreLayer
    class VPF,FPF,PF,CL,BP oracleLayer
    class GMX,GLP,USDG,WETH tokenLayer
    class V_BTC,V_ETH,V_USDC,V_OTHER vaultLayer
    class GOV,TIMELOCK,TR governanceLayer
```

### 核心合约结构

#### 1. Vault 合约 (`Vault.sol`)
- **功能**: 系统的核心金库，管理所有资金和仓位
- **主要职责**:
  - 存储和管理所有代币余额
  - 处理仓位的开仓、平仓和调整
  - 管理保证金和清算机制
  - 计算资金费率

#### 2. PositionManager 合约 (`PositionManager.sol`)
- **功能**: 管理用户仓位的创建和修改
- **主要职责**:
  - 处理仓位的增加和减少
  - 验证仓位参数（杠杆、保证金等）
  - 与 Vault 合约交互执行仓位操作

#### 3. Router 合约 (`Router.sol`)
- **功能**: 处理代币交换和路由
- **主要职责**:
  - 管理代币交换路径
  - 处理代币转账
  - 与外部 DEX 集成

#### 4. 价格预言机系统
- **VaultPriceFeed.sol**: 主要价格预言机合约
- **FastPriceFeed.sol**: 快速价格更新机制
- **PriceFeed.sol**: 价格数据存储和验证

#### 5. 代币系统

##### GLP 系统架构图

```mermaid
graph TB
    subgraph "GLP 系统架构"
        subgraph "用户层"
            LP[流动性提供者]
            TR[交易者]
        end
        
        subgraph "GLP 管理层"
            V[Vault<br/>核心金库]
            GLP[GLP Token<br/>流动性代币]
            USDG[USDG Token<br/>稳定币]
        end
        
        subgraph "资产池"
            BTC_POOL[BTC 池]
            ETH_POOL[ETH 池]
            USDC_POOL[USDC 池]
            OTHER_POOL[其他代币池]
        end
        
        subgraph "价格系统"
            VPF[VaultPriceFeed<br/>价格预言机]
            FPF[FastPriceFeed<br/>快速价格]
            CL[Chainlink]
        end
        
        subgraph "费用系统"
            TRADING_FEE[交易费用]
            FUNDING_FEE[资金费率]
            MINT_FEE[铸造费用]
        end
        
        subgraph "治理系统"
            GMX[GMX Token<br/>治理代币]
            GOV[Governable<br/>治理合约]
        end
    end
    
    %% 连接关系
    LP --> V
    TR --> V
    
    V --> GLP
    V --> USDG
    
    V --> BTC_POOL
    V --> ETH_POOL
    V --> USDC_POOL
    V --> OTHER_POOL
    
    V --> VPF
    VPF --> FPF
    FPF --> CL
    
    V --> TRADING_FEE
    V --> FUNDING_FEE
    V --> MINT_FEE
    
    V --> GMX
    GMX --> GOV
    
    %% 样式
    classDef userLayer fill:#e1f5fe
    classDef glpLayer fill:#fce4ec
    classDef poolLayer fill:#fff3e0
    classDef priceLayer fill:#e0f2f1
    classDef feeLayer fill:#e8f5e8
    classDef govLayer fill:#fafafa
    
    class LP,TR userLayer
    class V,GLP,USDG glpLayer
    class BTC_POOL,ETH_POOL,USDC_POOL,OTHER_POOL poolLayer
    class VPF,FPF,CL priceLayer
    class TRADING_FEE,FUNDING_FEE,MINT_FEE feeLayer
    class GMX,GOV govLayer
```

##### 代币系统
- **GMX.sol**: 治理代币
- **GLP.sol**: 流动性提供者代币
- **USDG.sol**: 稳定币代币

### 数据流架构

#### 交易流程架构图

```mermaid
sequenceDiagram
    participant U as 用户
    participant PM as PositionManager
    participant R as Router
    participant V as Vault
    participant VPF as VaultPriceFeed
    participant CL as Chainlink
    participant ST as ShortsTracker

    Note over U,ST: 开仓流程
    U->>PM: 创建仓位请求
    PM->>R: 处理代币交换
    R->>V: 转移代币到金库
    V-->>R: 确认代币接收
    R-->>PM: 返回交换结果
    PM->>VPF: 获取价格数据
    VPF->>CL: 查询Chainlink价格
    CL-->>VPF: 返回价格信息
    VPF-->>PM: 返回价格数据
    PM->>V: 创建仓位
    V->>ST: 更新空头跟踪
    ST-->>V: 确认更新
    V-->>PM: 返回仓位信息
    PM-->>U: 返回仓位创建结果

    Note over U,ST: 平仓流程
    U->>PM: 平仓请求
    PM->>VPF: 获取当前价格
    VPF->>CL: 查询最新价格
    CL-->>VPF: 返回价格信息
    VPF-->>PM: 返回价格数据
    PM->>V: 执行平仓
    V->>ST: 更新空头跟踪
    ST-->>V: 确认更新
    V->>V: 计算盈亏
    V->>R: 转移代币给用户
    R-->>V: 确认代币转移
    V-->>PM: 返回平仓结果
    PM-->>U: 返回平仓结果
```

#### 流动性提供流程架构图

```mermaid
sequenceDiagram
    participant LP as 流动性提供者
    participant V as Vault
    participant GLP as GLP Token
    participant VPF as VaultPriceFeed
    participant CL as Chainlink

    Note over LP,CL: 存款流程
    LP->>V: 存入代币
    V->>VPF: 获取代币价格
    VPF->>CL: 查询价格
    CL-->>VPF: 返回价格信息
    VPF-->>V: 返回价格数据
    V->>V: 计算GLP数量
    V->>GLP: 铸造GLP代币
    GLP-->>V: 确认铸造
    V-->>LP: 返回GLP代币

    Note over LP,CL: 提款流程
    LP->>V: 赎回GLP代币
    V->>GLP: 销毁GLP代币
    GLP-->>V: 确认销毁
    V->>VPF: 获取代币价格
    VPF->>CL: 查询价格
    CL-->>VPF: 返回价格信息
    VPF-->>V: 返回价格数据
    V->>V: 计算可提取代币数量
    V->>LP: 转移代币
    V-->>LP: 确认提款完成
```

#### 清算流程架构图

```mermaid
sequenceDiagram
    participant K as Keeper(清算者)
    participant PM as PositionManager
    participant V as Vault
    participant VPF as VaultPriceFeed
    participant CL as Chainlink
    participant U as 用户

    Note over K,U: 清算检测流程
    K->>V: 检查仓位健康度
    V->>VPF: 获取当前价格
    VPF->>CL: 查询价格
    CL-->>VPF: 返回价格信息
    VPF-->>V: 返回价格数据
    V->>V: 计算仓位价值
    V->>V: 检查是否低于清算阈值
    V-->>K: 返回清算状态

    Note over K,U: 清算执行流程
    K->>PM: 执行清算
    PM->>V: 获取仓位信息
    V-->>PM: 返回仓位数据
    PM->>VPF: 获取清算价格
    VPF->>CL: 查询价格
    CL-->>VPF: 返回价格信息
    VPF-->>PM: 返回价格数据
    PM->>V: 执行清算逻辑
    V->>V: 计算清算费用
    V->>V: 转移剩余资金给用户
    V-->>PM: 返回清算结果
    PM-->>K: 确认清算完成
```

#### 价格更新流程架构图

```mermaid
sequenceDiagram
    participant CL as Chainlink
    participant BP as Band Protocol
    participant FPF as FastPriceFeed
    participant VPF as VaultPriceFeed
    participant V as Vault
    participant PM as PositionManager

    Note over CL,PM: 价格更新流程
    CL->>FPF: 发送价格数据
    BP->>FPF: 发送价格数据
    FPF->>FPF: 聚合价格数据
    FPF->>VPF: 更新价格
    VPF->>V: 通知价格更新
    V->>V: 更新内部价格状态
    V->>PM: 通知价格变化
    PM->>PM: 检查待执行订单
    PM->>V: 执行符合条件的订单
    V-->>PM: 返回执行结果
```

### 关键机制

#### 1. 仓位管理
- 仓位结构包含：大小、保证金、平均价格、资金费率、储备金额等
- 支持多头和空头仓位
- 动态调整杠杆和保证金要求

#### 2. 清算机制
- 当仓位的保证金率低于最低要求时触发清算
- 清算费用为 100 USD
- 支持部分清算和完全清算

#### 3. 资金费率
- 每 8 小时更新一次
- 基于多空仓位不平衡计算
- 用于平衡多空仓位

#### 4. 费用结构
- 开仓费用：0.1%
- 平仓费用：0.1%
- 交换费用：0.3%（稳定币 0.04%）
- 铸造/销毁费用：0.3%

## 技术特点

### 1. 安全性
- 使用 OpenZeppelin 的安全库
- 重入攻击保护
- 权限管理系统
- 多重签名治理

### 2. 可升级性
- 使用代理模式支持合约升级
- 时间锁机制防止恶意升级
- 分阶段部署和验证

### 3. 效率优化
- 批量操作减少 Gas 消耗
- 优化的存储布局
- 事件驱动的状态更新

## 部署信息

### 网络支持
- **Arbitrum**: 主网部署
- **Avalanche**: 主网部署

### 主要合约地址
- Vault: 核心金库合约
- PositionManager: 仓位管理合约
- Router: 路由合约
- GLP: 流动性代币合约

## 使用场景

### 1. 交易者
- 进行高杠杆永续合约交易
- 利用低滑点进行大额交易
- 通过做空对冲风险

### 2. 流动性提供者
- 提供流动性获得 GLP 代币
- 通过交易费用和资金费率获得收益
- 参与治理决策

### 3. 套利者
- 利用价格差异进行套利
- 通过资金费率套利
- 跨链套利机会

## 风险提示

1. **智能合约风险**: 代码可能存在漏洞
2. **流动性风险**: 极端市场条件下可能出现流动性不足
3. **预言机风险**: 价格数据可能被操纵
4. **清算风险**: 高杠杆交易面临强制清算风险
5. **监管风险**: 不同司法管辖区可能有不同的监管要求

## 总结

GMX V1 是一个功能完整的去中心化永续合约交易协议，通过创新的 AMM 机制和去中心化预言机系统，为用户提供了高效、低成本的交易体验。其模块化的架构设计确保了系统的可维护性和可扩展性，为后续的 V2 升级奠定了基础。
