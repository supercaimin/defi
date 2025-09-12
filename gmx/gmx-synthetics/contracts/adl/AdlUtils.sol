// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../data/DataStore.sol";
import "../event/EventEmitter.sol";

import "../order/OrderStoreUtils.sol";
import "../order/OrderEventUtils.sol";
import "../position/PositionStoreUtils.sol";
import "../nonce/NonceUtils.sol";
import "../callback/CallbackUtils.sol";
import "../market/Market.sol";
import "../market/MarketUtils.sol";
import "../oracle/IOracle.sol";

// @title AdlUtils - 自动去杠杆工具库
// @dev 用于帮助处理自动去杠杆（Auto-Deleveraging, ADL）的库
// 这个库特别适用于指数代币与多头代币不同的市场场景
//
// 自动去杠杆机制的核心作用：
// 1. 防止系统因过度杠杆而破产
// 2. 确保流动性池的偿付能力
// 3. 在极端市场条件下保护协议和用户资金
//
// 实际应用场景举例：
// 假设存在一个DOGE/USD永续合约市场，但使用ETH作为多头代币
// 当DOGE价格相对于ETH快速上涨时，多头头寸会产生巨大未实现利润
// 如果这些利润超过流动性池的承受能力，系统就需要通过ADL机制
// 强制平仓部分盈利头寸，以确保系统保持完全偿付能力
//
// ADL触发条件：
// - 未实现利润与池价值的比率超过预设阈值
// - 系统检测到流动性风险
// - 预言机价格更新确认风险状态
library AdlUtils {
    // 类型转换和库函数导入
    using SafeCast for int256;           // 安全的int256类型转换，防止溢出
    using Market for Market.Props;       // 市场属性结构体的扩展方法
    using Position for Position.Props;   // 头寸属性结构体的扩展方法

    // 事件工具库的导入，用于构建和发射各种类型的事件数据
    using EventUtils for EventUtils.AddressItems;  // 地址数组事件数据
    using EventUtils for EventUtils.UintItems;     // 无符号整数数组事件数据
    using EventUtils for EventUtils.IntItems;      // 有符号整数数组事件数据
    using EventUtils for EventUtils.BoolItems;     // 布尔值数组事件数据
    using EventUtils for EventUtils.Bytes32Items;  // 32字节数组事件数据
    using EventUtils for EventUtils.BytesItems;    // 字节数组事件数据
    using EventUtils for EventUtils.StringItems;   // 字符串数组事件数据

    // @dev CreateAdlOrderParams - 创建ADL订单参数结构体
    // 此结构体用于createAdlOrder函数中，避免Solidity的"堆栈过深"错误
    // 当函数参数过多时，Solidity编译器会报错，使用结构体可以解决这个问题
    //
    // @param dataStore 数据存储合约，存储所有协议状态和配置
    // @param eventEmitter 事件发射器，用于记录和广播协议事件
    // @param account 需要减少头寸的账户地址
    // @param market 头寸所在的市场地址
    // @param collateralToken 头寸使用的抵押代币地址
    // @param isLong 头寸方向：true表示多头，false表示空头
    // @param sizeDeltaUsd 要减少的头寸大小（以USD计价）
    // @param updatedAtTime 订单创建时间戳，用于防止重放攻击
    struct CreateAdlOrderParams {
        DataStore dataStore;           // 数据存储合约实例
        EventEmitter eventEmitter;     // 事件发射器实例
        address account;               // 目标账户地址
        address market;                // 市场合约地址
        address collateralToken;       // 抵押代币地址
        bool isLong;                   // 头寸方向标志
        uint256 sizeDeltaUsd;          // 头寸减少金额（USD）
        uint256 updatedAtTime;         // 更新时间戳
    }

    // @dev updateAdlState - 更新ADL状态的核心函数
    // 
    // 功能说明：
    // 1. 检查当前市场状态是否需要进行自动去杠杆
    // 2. 计算未实现利润与流动性池价值的比率
    // 3. 根据预设阈值决定是否启用ADL机制
    // 4. 更新ADL状态标志，避免重复验证
    //
    // 为什么需要这个函数：
    // - 多个头寸可能需要被减少，以确保待处理利润不超过允许的阈值
    // - 只有当池处于需要自动去杠杆的状态时，才能进行头寸的自动减少
    // - 此函数检查待处理利润状态并更新isAdlEnabled标志，避免重复验证
    // - 一旦待处理利润减少到阈值以下，可以再次调用此函数清除标志
    //
    // 安全考虑：
    // - ADL检查也可以在AdlHandler.executeAdl中进行，但那样订单维护者
    //   可能使用过时的预言机价格来证明ADL状态是可能的
    // - 拥有此函数允许任何订单维护者在价格更新使得不再需要ADL时禁用ADL
    // - 这确保了ADL机制基于最新的价格数据运行
    //
    // @param dataStore 数据存储合约，包含所有市场配置和状态
    // @param eventEmitter 事件发射器，用于记录ADL状态变化
    // @param oracle 预言机合约，提供最新价格数据
    // @param market 要检查的市场地址
    // @param isLong 指示检查市场的多头侧(true)还是空头侧(false)
    function updateAdlState(
        DataStore dataStore,
        EventEmitter eventEmitter,
        IOracle oracle,
        address market,
        bool isLong
    ) external {
        // 步骤1：获取上次ADL更新的时间戳
        // 这个时间戳用于确保我们使用的是最新的价格数据
        uint256 latestAdlTime = getLatestAdlTime(dataStore, market, isLong);

        // 步骤2：验证预言机价格的时间戳
        // 如果预言机的最大时间戳小于上次ADL时间，说明价格数据过时
        // 这防止了使用过时价格进行ADL决策，确保系统安全
        if (oracle.maxTimestamp() < latestAdlTime) {
            revert Errors.OracleTimestampsAreSmallerThanRequired(oracle.maxTimestamp(), latestAdlTime);
        }

        // 步骤3：获取市场信息和当前价格
        // 从数据存储中获取启用的市场配置
        Market.Props memory _market = MarketUtils.getEnabledMarket(dataStore, market);
        // 从预言机获取当前市场价格（包括指数价格和长代币价格）
        MarketUtils.MarketPrices memory prices = MarketUtils.getMarketPrices(oracle, _market);
        
        // 步骤4：检查PnL因子是否超过阈值
        // 重要说明：如果MAX_PNL_FACTOR_FOR_ADL设置为高于MAX_PNL_FACTOR_FOR_WITHDRAWALS
        // 池可能处于既不允许提取也不允许ADL的状态
        // 这类似于相对于池中代币数量有大量未平仓头寸的情况
        // 这种情况下系统会进入"冻结"状态，直到风险降低
        (bool shouldEnableAdl, int256 pnlToPoolFactor, uint256 maxPnlFactor) = MarketUtils.isPnlFactorExceeded(
            dataStore,
            _market,
            prices,
            isLong,
            Keys.MAX_PNL_FACTOR_FOR_ADL
        );

        // 步骤5：更新ADL启用状态
        // 根据计算结果设置ADL是否应该启用
        setIsAdlEnabled(dataStore, market, isLong, shouldEnableAdl);
        
        // 步骤6：更新ADL时间戳
        // 安全考虑：由于ADL时间总是被更新，ADL维护者可能
        // 持续导致ADL时间被更新并阻止ADL订单被执行
        // 但是这可能比ADL维护者使用过时价格执行订单的情况更可取
        // 因此允许ADL时间的更新，并且期望ADL维护者保持此时间更新
        // 以便最新的价格将用于ADL决策
        setLatestAdlAt(dataStore, market, isLong, Chain.currentTimestamp());

        // 步骤7：发射ADL状态更新事件
        // 记录ADL状态变化，包括PnL比率、最大PnL因子和是否启用ADL
        emitAdlStateUpdated(eventEmitter, market, isLong, pnlToPoolFactor, maxPnlFactor, shouldEnableAdl);
    }

    // @dev createAdlOrder - 创建ADL订单的核心函数
    //
    // 功能说明：
    // 1. 构建一个减少头寸的订单，用于强制平仓盈利头寸
    // 2. 验证订单参数的合法性
    // 3. 设置订单的各种参数（地址、数量、标志等）
    // 4. 将订单存储到订单存储系统中
    // 5. 发射订单创建事件
    //
    // 订单类型：MarketDecrease（市价减少订单）
    // 这种订单会立即以当前市场价格执行，确保快速平仓
    //
    // 安全特性：
    // - 验证减少的头寸大小不超过当前头寸大小
    // - 使用最新的时间戳防止重放攻击
    // - 设置合适的交换类型确保费用可以正确计算
    //
    // @param params 创建ADL订单的参数结构体
    // @return 返回创建的订单的唯一标识符（key）
    function createAdlOrder(CreateAdlOrderParams memory params) external returns (bytes32) {
        // 步骤1：生成头寸键并获取头寸信息
        // 头寸键是账户、市场、抵押代币和方向的唯一标识符
        bytes32 positionKey = Position.getPositionKey(params.account, params.market, params.collateralToken, params.isLong);
        Position.Props memory position = PositionStoreUtils.get(params.dataStore, positionKey);

        // 步骤2：验证订单参数
        // 确保要减少的头寸大小不超过当前头寸大小
        // 这是防止过度平仓的重要安全检查
        if (params.sizeDeltaUsd > position.sizeInUsd()) {
            revert Errors.InvalidSizeDeltaForAdl(params.sizeDeltaUsd, position.sizeInUsd());
        }

        // 步骤3：构建订单地址信息
        // 设置订单相关的所有地址参数
        Order.Addresses memory addresses = Order.Addresses(
            params.account, // 账户地址 - 订单的所有者
            params.account, // 接收者地址 - 平仓后资金的接收者
            params.account, // 取消接收者地址 - 订单取消时资金的接收者
            CallbackUtils.getSavedCallbackContract(params.dataStore, params.account, params.market), // 回调合约地址
            address(0), // UI费用接收者地址 - 设置为0表示无UI费用
            params.market, // 市场地址 - 订单所在的市场
            position.collateralToken(), // 初始抵押代币地址 - 头寸的抵押代币
            new address[](0) // 交换路径 - 空数组表示直接交换
        );

        // 步骤4：获取源链ID
        // 用于跨链操作，记录头寸最后更新的源链
        uint256 lastSrcChainId = params.dataStore.getUint(Keys.positionLastSrcChainId(positionKey));

        // 步骤5：构建订单数量参数
        // 
        // 重要设计决策说明：
        // 1. 滑点设置：此订单未设置滑点限制，这对于ADL订单可能更可取
        //    在价格影响较大的情况下，用户可以通过协议基金获得退款
        //    此金额稍后可以从价格影响池中提取（如果需要，应该添加此提取过程）
        //
        // 2. 价格影响考虑：设置适用于大多数情况的最大价格影响可能具有挑战性
        //    因为价格影响会根据被交换的抵押品数量而变化
        //
        // 3. 交换类型选择：decreasePositionSwapType应该设置为SwapPnlTokenToCollateralToken
        //    因为费用是参考抵押代币计算的
        //    如果输出代币与抵押代币相同，费用会从输出金额中扣除
        //    将PnL代币交换为抵押代币有助于确保可以使用已实现利润支付费用
        Order.Numbers memory numbers = Order.Numbers(
            Order.OrderType.MarketDecrease, // 订单类型：市价减少订单
            Order.DecreasePositionSwapType.SwapPnlTokenToCollateralToken, // 减少头寸交换类型
            params.sizeDeltaUsd, // 头寸减少金额（USD）
            0, // 初始抵押品变化金额（ADL不需要增加抵押品）
            0, // 触发价格（市价订单不需要触发价格）
            position.isLong() ? 0 : type(uint256).max, // 可接受价格（多头为0，空头为最大值）
            0, // 执行费用（ADL订单通常免收执行费用）
            params.dataStore.getUint(Keys.MAX_CALLBACK_GAS_LIMIT), // 回调Gas限制
            0, // 最小输出金额（不设置最小输出限制）
            params.updatedAtTime, // 更新时间戳
            0, // 有效开始时间（立即有效）
            lastSrcChainId // 源链ID
        );

        // 步骤6：构建订单标志
        // 设置订单的各种布尔标志
        Order.Flags memory flags = Order.Flags(
            position.isLong(), // 是否多头头寸
            lastSrcChainId == 0, // 是否解包原生代币（如果源链ID为0则解包）
            false, // 是否冻结（ADL订单不冻结）
            false // 是否自动取消（ADL订单不自动取消）
        );

        // 步骤7：组装完整订单
        // 将所有组件组合成完整的订单对象
        Order.Props memory order = Order.Props(
            addresses, // 地址信息
            numbers,   // 数量信息
            flags,     // 标志信息
            new bytes32[](0) // 额外的字节32数组（ADL订单不需要）
        );

        // 步骤8：生成订单键并存储订单
        // 使用NonceUtils生成唯一的订单键，确保订单ID的唯一性
        bytes32 key = NonceUtils.getNextKey(params.dataStore);
        // 将订单存储到数据存储中
        OrderStoreUtils.set(params.dataStore, key, order);

        // 步骤9：发射订单创建事件
        // 通知系统和其他监听者订单已被创建
        OrderEventUtils.emitOrderCreated(params.eventEmitter, key, order);

        // 步骤10：返回订单键
        // 返回新创建订单的唯一标识符
        return key;
    }

    // @dev validateAdl - 验证请求的ADL是否可以执行
    //
    // 功能说明：
    // 1. 检查ADL是否已启用
    // 2. 验证预言机价格数据是否足够新
    // 3. 确保ADL执行的安全性和时效性
    //
    // 验证条件：
    // - ADL必须已启用（通过updateAdlState函数设置）
    // - 预言机价格时间戳必须大于等于上次ADL更新时间
    // - 这确保ADL基于最新的价格数据执行
    //
    // 使用场景：
    // - 在AdlHandler.executeAdl中调用，确保ADL执行前的最后验证
    // - 防止使用过时价格执行ADL，保护系统安全
    //
    // @param dataStore 数据存储合约，包含ADL状态信息
    // @param oracle 预言机合约，提供价格数据
    // @param market 要检查的市场地址
    // @param isLong 指示检查市场的多头侧(true)还是空头侧(false)
    function validateAdl(
        DataStore dataStore,
        IOracle oracle,
        address market,
        bool isLong
    ) external view {
        // 检查1：验证ADL是否已启用
        // 如果ADL未启用，则不允许执行ADL操作
        bool isAdlEnabled = AdlUtils.getIsAdlEnabled(dataStore, market, isLong);
        if (!isAdlEnabled) {
            revert Errors.AdlNotEnabled();
        }

        // 检查2：验证预言机价格数据的新鲜度
        // 确保使用的价格数据不比上次ADL更新更旧
        // 这防止了使用过时价格进行ADL决策
        uint256 latestAdlTime = AdlUtils.getLatestAdlTime(dataStore, market, isLong);
        if (oracle.maxTimestamp() < latestAdlTime) {
            revert Errors.OracleTimestampsAreSmallerThanRequired(oracle.maxTimestamp(), latestAdlTime);
        }
    }

    // @dev getLatestAdlTime - 获取ADL标志最后更新的时间
    //
    // 功能说明：
    // 获取指定市场和方向（多头/空头）的ADL状态最后更新时间戳
    // 这个时间戳用于确保ADL决策基于最新的价格数据
    //
    // 使用场景：
    // - 在updateAdlState中检查价格数据的新鲜度
    // - 在validateAdl中验证ADL执行条件
    // - 防止使用过时价格进行ADL操作
    //
    // @param dataStore 数据存储合约，包含ADL时间信息
    // @param market 要检查的市场地址
    // @param isLong 指示检查市场的多头侧(true)还是空头侧(false)
    // @return 返回ADL标志最后更新的时间戳
    function getLatestAdlTime(DataStore dataStore, address market, bool isLong) internal view returns (uint256) {
        return dataStore.getUint(Keys.latestAdlAtKey(market, isLong));
    }

    // @dev setLatestAdlAt - 设置ADL标志最后更新的时间
    //
    // 功能说明：
    // 更新指定市场和方向的ADL状态最后更新时间戳
    // 每次ADL状态更新时都会调用此函数
    //
    // 安全考虑：
    // - 时间戳的更新允许ADL维护者持续更新ADL时间
    // - 这比使用过时价格执行ADL更安全
    // - 确保ADL基于最新的价格数据运行
    //
    // @param dataStore 数据存储合约，用于存储ADL时间
    // @param market 要更新的市场地址
    // @param isLong 指示更新市场的多头侧(true)还是空头侧(false)
    // @param value 新的时间戳值
    // @return 返回设置的时间戳值
    function setLatestAdlAt(DataStore dataStore, address market, bool isLong, uint256 value) internal returns (uint256) {
        return dataStore.setUint(Keys.latestAdlAtKey(market, isLong), value);
    }

    // @dev getIsAdlEnabled - 获取ADL是否启用
    //
    // 功能说明：
    // 检查指定市场和方向（多头/空头）的ADL是否已启用
    // 这个标志由updateAdlState函数根据市场风险状况设置
    //
    // 返回值说明：
    // - true: ADL已启用，可以执行ADL操作
    // - false: ADL未启用，不允许执行ADL操作
    //
    // @param dataStore 数据存储合约，包含ADL状态信息
    // @param market 要检查的市场地址
    // @param isLong 指示检查市场的多头侧(true)还是空头侧(false)
    // @return 返回ADL是否启用的布尔值
    function getIsAdlEnabled(DataStore dataStore, address market, bool isLong) internal view returns (bool) {
        return dataStore.getBool(Keys.isAdlEnabledKey(market, isLong));
    }

    // @dev setIsAdlEnabled - 设置ADL是否启用
    //
    // 功能说明：
    // 设置指定市场和方向的ADL启用状态
    // 这个函数由updateAdlState调用，根据市场风险状况决定是否启用ADL
    //
    // 状态设置逻辑：
    // - 当PnL因子超过阈值时，启用ADL
    // - 当风险降低到安全水平时，禁用ADL
    // - 状态变化会通过事件记录
    //
    // @param dataStore 数据存储合约，用于存储ADL状态
    // @param market 要设置的市场地址
    // @param isLong 指示设置市场的多头侧(true)还是空头侧(false)
    // @param value ADL是否启用的布尔值
    // @return 返回设置的布尔值
    function setIsAdlEnabled(DataStore dataStore, address market, bool isLong, bool value) internal returns (bool) {
        return dataStore.setBool(Keys.isAdlEnabledKey(market, isLong), value);
    }

    // @dev emitAdlStateUpdated - 发射ADL状态更新事件
    //
    // 功能说明：
    // 1. 构建包含ADL状态信息的结构化事件数据
    // 2. 发射"AdlStateUpdated"事件，记录ADL状态变化
    // 3. 提供完整的状态信息供外部监听者使用
    //
    // 事件数据结构：
    // - pnlToPoolFactor: PnL与池价值的比率（有符号整数）
    // - maxPnlFactor: 最大PnL因子（无符号整数）
    // - isLong: 是否为多头侧（布尔值）
    // - shouldEnableAdl: 是否应该启用ADL（布尔值）
    //
    // 使用场景：
    // - 监控系统可以监听此事件来跟踪ADL状态变化
    // - 前端界面可以实时显示ADL状态
    // - 风险管理系统可以基于此事件进行决策
    //
    // @param eventEmitter 事件发射器合约实例
    // @param market ADL状态更新的市场地址
    // @param isLong 指示ADL状态更新是用于市场的多头侧(true)还是空头侧(false)
    // @param pnlToPoolFactor PnL与池价值的比率，用于衡量风险水平
    // @param maxPnlFactor 最大PnL因子，系统允许的最大风险阈值
    // @param shouldEnableAdl ADL是否被启用或禁用，决定是否可以执行ADL操作
    function emitAdlStateUpdated(
        EventEmitter eventEmitter,
        address market,
        bool isLong,
        int256 pnlToPoolFactor,
        uint256 maxPnlFactor,
        bool shouldEnableAdl
    ) internal {
        // 创建事件数据结构
        EventUtils.EventLogData memory eventData;

        // 初始化有符号整数数组，存储PnL比率
        eventData.intItems.initItems(1);
        eventData.intItems.setItem(0, "pnlToPoolFactor", pnlToPoolFactor);

        // 初始化无符号整数数组，存储最大PnL因子
        eventData.uintItems.initItems(1);
        eventData.uintItems.setItem(0, "maxPnlFactor", maxPnlFactor);

        // 初始化布尔值数组，存储方向标志和ADL启用状态
        eventData.boolItems.initItems(2);
        eventData.boolItems.setItem(0, "isLong", isLong);
        eventData.boolItems.setItem(1, "shouldEnableAdl", shouldEnableAdl);

        // 发射ADL状态更新事件
        // 事件名称："AdlStateUpdated"
        // 事件数据：市场地址和结构化的事件数据
        eventEmitter.emitEventLog1(
            "AdlStateUpdated",
            Cast.toBytes32(market),
            eventData
        );
    }
}
