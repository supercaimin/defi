pragma solidity =0.6.6;

/**
 * @title UniswapV2Router02
 * @notice Uniswap V2 路由器合约，提供用户友好的接口来与 Uniswap V2 协议交互
 * @dev 这是 Uniswap V2 生态系统的核心路由器，负责处理所有用户操作
 * 
 * 主要功能：
 * 1. 流动性管理：添加和移除流动性，支持 ERC20-ERC20 和 ERC20-ETH 交易对
 * 2. 代币交换：执行各种代币交换操作，支持多跳路径
 * 3. ETH 处理：通过 WETH 包装/解包处理 ETH 交易
 * 4. 费用代币支持：支持有转账费用的代币
 * 5. 权限管理：支持 permit 签名授权，无需预授权
 * 6. 路径优化：自动计算最优交换路径
 * 
 * 核心设计理念：
 * - 用户友好：提供简单易用的接口
 * - 安全性：实现多重安全检查机制
 * - 灵活性：支持各种代币类型和交换场景
 * - 效率：优化 Gas 使用和交易路径
 * - 兼容性：支持标准和非标准 ERC20 代币
 * 
 * 技术实现：
 * - 使用工厂合约创建和管理交易对
 * - 通过 WETH 实现 ETH 与 ERC20 的互操作
 * - 实现多跳交换路径优化
 * - 支持费用代币的特殊处理
 * - 提供签名授权功能减少交易次数
 */

// 核心接口
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
// 安全转账库
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

// 路由器接口
import './interfaces/IUniswapV2Router02.sol';
// 核心计算库
import './libraries/UniswapV2Library.sol';
// 安全数学库
import './libraries/SafeMath.sol';
// ERC20 代币接口
import './interfaces/IERC20.sol';
// WETH 包装以太币接口
import './interfaces/IWETH.sol';

/// @title Uniswap V2 路由器合约
/// @notice 提供用户友好的接口来与 Uniswap V2 协议交互
contract UniswapV2Router02 is IUniswapV2Router02 {
    // ============ 库函数修饰符 ============
    
    using SafeMath for uint; // 安全数学运算

    // ============ 状态变量 ============
    
    /// @notice 工厂合约地址
    /// @dev 用于创建和访问交易对合约
    address public immutable override factory;
    
    /// @notice WETH 合约地址
    /// @dev 用于处理 ETH 与 ERC20 代币的转换
    address public immutable override WETH;

    // ============ 修饰符 ============
    
    /// @notice 截止时间检查修饰符
    /// @dev 确保交易在截止时间之前执行
    /// @param deadline 交易截止时间戳
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    // ============ 构造函数和接收函数 ============
    
    /// @notice 构造函数
    /// @dev 初始化工厂合约和 WETH 合约地址
    /// @param _factory 工厂合约地址
    /// @param _WETH WETH 合约地址
    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    /// @notice 接收以太币函数
    /// @dev 只接受来自 WETH 合约的回调转账
    receive() external payable {
        assert(msg.sender == WETH); // 只接受来自 WETH 合约的回调转账
    }

    // ============ 添加流动性函数 ============
    
    /// @notice 内部添加流动性函数
    /// @dev 计算最优的代币数量并创建交易对（如果不存在）
    /// 
    /// 工作流程：
    /// 1. 检查交易对是否存在，不存在则创建
    /// 2. 获取当前储备量
    /// 3. 如果是首次添加，使用期望数量
    /// 4. 如果不是首次添加，计算最优比例
    /// 5. 验证最小数量要求
    /// 
    /// 最优数量计算：
    /// - 如果 amountBOptimal <= amountBDesired，使用 amountADesired 和 amountBOptimal
    /// - 否则使用 amountAOptimal 和 amountBDesired
    /// 
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @param amountADesired 期望的 tokenA 数量
    /// @param amountBDesired 期望的 tokenB 数量
    /// @param amountAMin 最小 tokenA 数量
    /// @param amountBMin 最小 tokenB 数量
    /// @return amountA 实际使用的 tokenA 数量
    /// @return amountB 实际使用的 tokenB 数量
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        // 如果交易对不存在，创建它
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        
        // 获取当前储备量
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        
        if (reserveA == 0 && reserveB == 0) {
            // 首次添加流动性，使用期望数量
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            // 计算最优的 tokenB 数量
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            
            if (amountBOptimal <= amountBDesired) {
                // 如果最优数量小于等于期望数量，使用 tokenA 的期望数量
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                // 否则计算最优的 tokenA 数量
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    /// @notice 添加 ERC20-ERC20 流动性
    /// @dev 向交易对添加流动性，铸造 LP 代币
    /// 
    /// 工作流程：
    /// 1. 计算最优代币数量
    /// 2. 获取交易对地址
    /// 3. 从用户转移代币到交易对
    /// 4. 调用交易对的 mint 函数铸造 LP 代币
    /// 
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @param amountADesired 期望的 tokenA 数量
    /// @param amountBDesired 期望的 tokenB 数量
    /// @param amountAMin 最小 tokenA 数量（滑点保护）
    /// @param amountBMin 最小 tokenB 数量（滑点保护）
    /// @param to 接收 LP 代币的地址
    /// @param deadline 交易截止时间
    /// @return amountA 实际使用的 tokenA 数量
    /// @return amountB 实际使用的 tokenB 数量
    /// @return liquidity 铸造的 LP 代币数量
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        // 计算最优代币数量
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        
        // 获取交易对地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 从用户转移代币到交易对
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        
        // 铸造 LP 代币
        liquidity = IUniswapV2Pair(pair).mint(to);
    }
    
    /// @notice 添加 ERC20-ETH 流动性
    /// @dev 向交易对添加流动性，支持 ETH 和 ERC20 代币
    /// 
    /// 工作流程：
    /// 1. 计算最优代币数量（将 ETH 作为 WETH 处理）
    /// 2. 获取交易对地址
    /// 3. 从用户转移 ERC20 代币到交易对
    /// 4. 将 ETH 包装为 WETH 并转移到交易对
    /// 5. 调用交易对的 mint 函数铸造 LP 代币
    /// 6. 退还多余的 ETH（如果有）
    /// 
    /// @param token ERC20 代币地址
    /// @param amountTokenDesired 期望的代币数量
    /// @param amountTokenMin 最小代币数量（滑点保护）
    /// @param amountETHMin 最小 ETH 数量（滑点保护）
    /// @param to 接收 LP 代币的地址
    /// @param deadline 交易截止时间
    /// @return amountToken 实际使用的代币数量
    /// @return amountETH 实际使用的 ETH 数量
    /// @return liquidity 铸造的 LP 代币数量
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        // 计算最优代币数量（将 ETH 作为 WETH 处理）
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        
        // 获取交易对地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        
        // 从用户转移 ERC20 代币到交易对
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        
        // 将 ETH 包装为 WETH 并转移到交易对
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        
        // 铸造 LP 代币
        liquidity = IUniswapV2Pair(pair).mint(to);
        
        // 退还多余的 ETH（如果有）
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // ============ 移除流动性函数 ============
    
    /// @notice 移除 ERC20-ERC20 流动性
    /// @dev 销毁 LP 代币并取回基础代币
    /// 
    /// 工作流程：
    /// 1. 获取交易对地址
    /// 2. 将 LP 代币从用户转移到交易对
    /// 3. 调用交易对的 burn 函数销毁 LP 代币
    /// 4. 根据代币排序调整返回数量
    /// 5. 验证最小数量要求
    /// 
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @param liquidity 要销毁的 LP 代币数量
    /// @param amountAMin 最小 tokenA 数量（滑点保护）
    /// @param amountBMin 最小 tokenB 数量（滑点保护）
    /// @param to 接收代币的地址
    /// @param deadline 交易截止时间
    /// @return amountA 取回的 tokenA 数量
    /// @return amountB 取回的 tokenB 数量
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        // 获取交易对地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 将 LP 代币从用户转移到交易对
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
        
        // 销毁 LP 代币并获取基础代币
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        
        // 根据代币排序调整返回数量
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        
        // 验证最小数量要求
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }
    
    /// @notice 移除 ERC20-ETH 流动性
    /// @dev 销毁 LP 代币并取回基础代币，将 WETH 转换为 ETH
    /// 
    /// 工作流程：
    /// 1. 调用 removeLiquidity 移除流动性（WETH 作为 tokenB）
    /// 2. 将 ERC20 代币转移给用户
    /// 3. 将 WETH 解包为 ETH 并转移给用户
    /// 
    /// @param token ERC20 代币地址
    /// @param liquidity 要销毁的 LP 代币数量
    /// @param amountTokenMin 最小代币数量（滑点保护）
    /// @param amountETHMin 最小 ETH 数量（滑点保护）
    /// @param to 接收代币的地址
    /// @param deadline 交易截止时间
    /// @return amountToken 取回的代币数量
    /// @return amountETH 取回的 ETH 数量
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {
        // 移除流动性（WETH 作为 tokenB）
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        
        // 将 ERC20 代币转移给用户
        TransferHelper.safeTransfer(token, to, amountToken);
        
        // 将 WETH 解包为 ETH 并转移给用户
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    /// @notice 带 permit 签名的移除 ERC20-ERC20 流动性
    /// @dev 使用签名授权移除流动性，无需预授权
    /// 
    /// 工作流程：
    /// 1. 获取交易对地址
    /// 2. 使用 permit 签名授权路由器转移 LP 代币
    /// 3. 调用 removeLiquidity 移除流动性
    /// 
    /// @param tokenA 第一个代币地址
    /// @param tokenB 第二个代币地址
    /// @param liquidity 要销毁的 LP 代币数量
    /// @param amountAMin 最小 tokenA 数量（滑点保护）
    /// @param amountBMin 最小 tokenB 数量（滑点保护）
    /// @param to 接收代币的地址
    /// @param deadline 交易截止时间
    /// @param approveMax 是否授权最大数量
    /// @param v 签名的 v 值
    /// @param r 签名的 r 值
    /// @param s 签名的 s 值
    /// @return amountA 取回的 tokenA 数量
    /// @return amountB 取回的 tokenB 数量
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountA, uint amountB) {
        // 获取交易对地址
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        
        // 使用 permit 签名授权路由器转移 LP 代币
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        
        // 移除流动性
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    
    /// @notice 带 permit 签名的移除 ERC20-ETH 流动性
    /// @dev 使用签名授权移除流动性，无需预授权
    /// 
    /// 工作流程：
    /// 1. 获取交易对地址
    /// 2. 使用 permit 签名授权路由器转移 LP 代币
    /// 3. 调用 removeLiquidityETH 移除流动性
    /// 
    /// @param token ERC20 代币地址
    /// @param liquidity 要销毁的 LP 代币数量
    /// @param amountTokenMin 最小代币数量（滑点保护）
    /// @param amountETHMin 最小 ETH 数量（滑点保护）
    /// @param to 接收代币的地址
    /// @param deadline 交易截止时间
    /// @param approveMax 是否授权最大数量
    /// @param v 签名的 v 值
    /// @param r 签名的 r 值
    /// @param s 签名的 s 值
    /// @return amountToken 取回的代币数量
    /// @return amountETH 取回的 ETH 数量
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        // 获取交易对地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        
        // 使用 permit 签名授权路由器转移 LP 代币
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        
        // 移除流动性
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // ============ 支持费用代币的移除流动性函数 ============
    
    /// @notice 支持费用代币的移除 ERC20-ETH 流动性
    /// @dev 专门处理有转账费用的代币，使用实际余额而不是预期数量
    /// 
    /// 工作流程：
    /// 1. 调用 removeLiquidity 移除流动性（代币转到合约地址）
    /// 2. 获取合约中代币的实际余额
    /// 3. 将实际余额转移给用户
    /// 4. 将 WETH 解包为 ETH 并转移给用户
    /// 
    /// @param token ERC20 代币地址（支持转账费用）
    /// @param liquidity 要销毁的 LP 代币数量
    /// @param amountTokenMin 最小代币数量（滑点保护）
    /// @param amountETHMin 最小 ETH 数量（滑点保护）
    /// @param to 接收代币的地址
    /// @param deadline 交易截止时间
    /// @return amountETH 取回的 ETH 数量
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        // 移除流动性（代币转到合约地址）
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        
        // 获取合约中代币的实际余额并转移给用户
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        
        // 将 WETH 解包为 ETH 并转移给用户
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    
    /// @notice 带 permit 签名的支持费用代币的移除 ERC20-ETH 流动性
    /// @dev 使用签名授权移除流动性，支持有转账费用的代币
    /// 
    /// 工作流程：
    /// 1. 获取交易对地址
    /// 2. 使用 permit 签名授权路由器转移 LP 代币
    /// 3. 调用 removeLiquidityETHSupportingFeeOnTransferTokens 移除流动性
    /// 
    /// @param token ERC20 代币地址（支持转账费用）
    /// @param liquidity 要销毁的 LP 代币数量
    /// @param amountTokenMin 最小代币数量（滑点保护）
    /// @param amountETHMin 最小 ETH 数量（滑点保护）
    /// @param to 接收代币的地址
    /// @param deadline 交易截止时间
    /// @param approveMax 是否授权最大数量
    /// @param v 签名的 v 值
    /// @param r 签名的 r 值
    /// @param s 签名的 s 值
    /// @return amountETH 取回的 ETH 数量
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountETH) {
        // 获取交易对地址
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        
        // 使用 permit 签名授权路由器转移 LP 代币
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        
        // 移除流动性
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    // ============ 代币交换函数 ============
    
    /// @notice 内部交换函数
    /// @dev 执行多跳代币交换，需要初始数量已发送到第一个交易对
    /// 
    /// 工作流程：
    /// 1. 遍历交换路径中的每个交易对
    /// 2. 确定输入和输出代币
    /// 3. 根据代币排序确定输出数量
    /// 4. 确定接收者地址（中间跳转到下一个交易对，最后一跳转到最终接收者）
    /// 5. 调用交易对的 swap 函数执行交换
    /// 
    /// @param amounts 每跳的交换数量数组
    /// @param path 交换路径（代币地址数组）
    /// @param _to 最终接收者地址
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            // 获取当前跳的输入和输出代币
            (address input, address output) = (path[i], path[i + 1]);
            
            // 对代币进行排序
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            
            // 获取输出数量
            uint amountOut = amounts[i + 1];
            
            // 根据代币排序确定输出数量
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            
            // 确定接收者地址
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            
            // 执行交换
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }
    /// @notice 精确输入代币数量交换代币
    /// @dev 使用精确的输入数量交换代币，输出数量可能有滑点
    /// 
    /// 工作流程：
    /// 1. 计算每跳的交换数量
    /// 2. 验证最终输出数量满足最小要求
    /// 3. 从用户转移输入代币到第一个交易对
    /// 4. 执行多跳交换
    /// 
    /// @param amountIn 输入代币数量
    /// @param amountOutMin 最小输出代币数量（滑点保护）
    /// @param path 交换路径（代币地址数组）
    /// @param to 接收输出代币的地址
    /// @param deadline 交易截止时间
    /// @return amounts 每跳的交换数量数组
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 计算每跳的交换数量
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        
        // 验证最终输出数量满足最小要求
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        // 从用户转移输入代币到第一个交易对
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        
        // 执行多跳交换
        _swap(amounts, path, to);
    }
    
    /// @notice 精确输出代币数量交换代币
    /// @dev 使用精确的输出数量交换代币，输入数量可能有滑点
    /// 
    /// 工作流程：
    /// 1. 计算每跳的交换数量
    /// 2. 验证输入数量不超过最大限制
    /// 3. 从用户转移输入代币到第一个交易对
    /// 4. 执行多跳交换
    /// 
    /// @param amountOut 输出代币数量
    /// @param amountInMax 最大输入代币数量（滑点保护）
    /// @param path 交换路径（代币地址数组）
    /// @param to 接收输出代币的地址
    /// @param deadline 交易截止时间
    /// @return amounts 每跳的交换数量数组
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        // 计算每跳的交换数量
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        
        // 验证输入数量不超过最大限制
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        
        // 从用户转移输入代币到第一个交易对
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        
        // 执行多跳交换
        _swap(amounts, path, to);
    }
    /// @notice 精确 ETH 数量交换代币
    /// @dev 使用精确的 ETH 数量交换代币，输出数量可能有滑点
    /// 
    /// 工作流程：
    /// 1. 验证路径以 WETH 开始
    /// 2. 计算每跳的交换数量
    /// 3. 验证最终输出数量满足最小要求
    /// 4. 将 ETH 包装为 WETH
    /// 5. 将 WETH 转移到第一个交易对
    /// 6. 执行多跳交换
    /// 
    /// @param amountOutMin 最小输出代币数量（滑点保护）
    /// @param path 交换路径（必须以 WETH 开始）
    /// @param to 接收输出代币的地址
    /// @param deadline 交易截止时间
    /// @return amounts 每跳的交换数量数组
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        // 验证路径以 WETH 开始
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        
        // 计算每跳的交换数量
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        
        // 验证最终输出数量满足最小要求
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        // 将 ETH 包装为 WETH
        IWETH(WETH).deposit{value: amounts[0]}();
        
        // 将 WETH 转移到第一个交易对
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        
        // 执行多跳交换
        _swap(amounts, path, to);
    }
    
    /// @notice 精确输出 ETH 数量交换代币
    /// @dev 使用精确的输出 ETH 数量交换代币，输入数量可能有滑点
    /// 
    /// 工作流程：
    /// 1. 验证路径以 WETH 结束
    /// 2. 计算每跳的交换数量
    /// 3. 验证输入数量不超过最大限制
    /// 4. 从用户转移输入代币到第一个交易对
    /// 5. 执行多跳交换（输出到合约地址）
    /// 6. 将 WETH 解包为 ETH 并转移给用户
    /// 
    /// @param amountOut 输出 ETH 数量
    /// @param amountInMax 最大输入代币数量（滑点保护）
    /// @param path 交换路径（必须以 WETH 结束）
    /// @param to 接收 ETH 的地址
    /// @param deadline 交易截止时间
    /// @return amounts 每跳的交换数量数组
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        // 验证路径以 WETH 结束
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        
        // 计算每跳的交换数量
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        
        // 验证输入数量不超过最大限制
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        
        // 从用户转移输入代币到第一个交易对
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        
        // 执行多跳交换（输出到合约地址）
        _swap(amounts, path, address(this));
        
        // 将 WETH 解包为 ETH 并转移给用户
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    /// @notice 精确输入代币数量交换 ETH
    /// @dev 使用精确的输入代币数量交换 ETH，输出数量可能有滑点
    /// 
    /// 工作流程：
    /// 1. 验证路径以 WETH 结束
    /// 2. 计算每跳的交换数量
    /// 3. 验证最终输出数量满足最小要求
    /// 4. 从用户转移输入代币到第一个交易对
    /// 5. 执行多跳交换（输出到合约地址）
    /// 6. 将 WETH 解包为 ETH 并转移给用户
    /// 
    /// @param amountIn 输入代币数量
    /// @param amountOutMin 最小输出 ETH 数量（滑点保护）
    /// @param path 交换路径（必须以 WETH 结束）
    /// @param to 接收 ETH 的地址
    /// @param deadline 交易截止时间
    /// @return amounts 每跳的交换数量数组
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        // 验证路径以 WETH 结束
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        
        // 计算每跳的交换数量
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        
        // 验证最终输出数量满足最小要求
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        // 从用户转移输入代币到第一个交易对
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        
        // 执行多跳交换（输出到合约地址）
        _swap(amounts, path, address(this));
        
        // 将 WETH 解包为 ETH 并转移给用户
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    
    /// @notice 精确输出代币数量交换 ETH
    /// @dev 使用精确的输出代币数量交换 ETH，输入数量可能有滑点
    /// 
    /// 工作流程：
    /// 1. 验证路径以 WETH 开始
    /// 2. 计算每跳的交换数量
    /// 3. 验证输入数量不超过发送的 ETH 数量
    /// 4. 将 ETH 包装为 WETH
    /// 5. 将 WETH 转移到第一个交易对
    /// 6. 执行多跳交换
    /// 7. 退还多余的 ETH（如果有）
    /// 
    /// @param amountOut 输出代币数量
    /// @param path 交换路径（必须以 WETH 开始）
    /// @param to 接收输出代币的地址
    /// @param deadline 交易截止时间
    /// @return amounts 每跳的交换数量数组
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        // 验证路径以 WETH 开始
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        
        // 计算每跳的交换数量
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        
        // 验证输入数量不超过发送的 ETH 数量
        require(amounts[0] <= msg.value, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        
        // 将 ETH 包装为 WETH
        IWETH(WETH).deposit{value: amounts[0]}();
        
        // 将 WETH 转移到第一个交易对
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        
        // 执行多跳交换
        _swap(amounts, path, to);
        
        // 退还多余的 ETH（如果有）
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // ============ 支持费用代币的交换函数 ============
    
    /// @notice 内部支持费用代币的交换函数
    /// @dev 专门处理有转账费用的代币，使用实际余额而不是预期数量
    /// 需要初始数量已发送到第一个交易对
    /// 
    /// 工作流程：
    /// 1. 遍历交换路径中的每个交易对
    /// 2. 确定输入和输出代币
    /// 3. 获取交易对的储备量
    /// 4. 计算实际输入数量（当前余额 - 储备量）
    /// 5. 根据实际输入数量计算输出数量
    /// 6. 执行交换
    /// 
    /// @param path 交换路径（代币地址数组）
    /// @param _to 最终接收者地址
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            // 获取当前跳的输入和输出代币
            (address input, address output) = (path[i], path[i + 1]);
            
            // 对代币进行排序
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            
            // 获取交易对合约
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));
            
            uint amountInput;
            uint amountOutput;
            
            { // 作用域用于避免堆栈过深错误
                // 获取交易对储备量
                (uint reserve0, uint reserve1,) = pair.getReserves();
                (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                
                // 计算实际输入数量（当前余额 - 储备量）
                amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
                
                // 根据实际输入数量计算输出数量
                amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            
            // 根据代币排序确定输出数量
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            
            // 确定接收者地址
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            
            // 执行交换
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    /// @notice 支持费用代币的精确输入代币数量交换代币
    /// @dev 专门处理有转账费用的代币，使用实际余额验证输出数量
    /// 
    /// 工作流程：
    /// 1. 从用户转移输入代币到第一个交易对
    /// 2. 记录接收者的代币余额
    /// 3. 执行支持费用代币的交换
    /// 4. 验证实际接收的代币数量满足最小要求
    /// 
    /// @param amountIn 输入代币数量
    /// @param amountOutMin 最小输出代币数量（滑点保护）
    /// @param path 交换路径（代币地址数组）
    /// @param to 接收输出代币的地址
    /// @param deadline 交易截止时间
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        // 从用户转移输入代币到第一个交易对
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        
        // 记录接收者的代币余额
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        
        // 执行支持费用代币的交换
        _swapSupportingFeeOnTransferTokens(path, to);
        
        // 验证实际接收的代币数量满足最小要求
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    
    /// @notice 支持费用代币的精确 ETH 数量交换代币
    /// @dev 专门处理有转账费用的代币，使用实际余额验证输出数量
    /// 
    /// 工作流程：
    /// 1. 验证路径以 WETH 开始
    /// 2. 将 ETH 包装为 WETH
    /// 3. 将 WETH 转移到第一个交易对
    /// 4. 记录接收者的代币余额
    /// 5. 执行支持费用代币的交换
    /// 6. 验证实际接收的代币数量满足最小要求
    /// 
    /// @param amountOutMin 最小输出代币数量（滑点保护）
    /// @param path 交换路径（必须以 WETH 开始）
    /// @param to 接收输出代币的地址
    /// @param deadline 交易截止时间
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        // 验证路径以 WETH 开始
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        
        // 将 ETH 包装为 WETH
        uint amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        
        // 将 WETH 转移到第一个交易对
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));
        
        // 记录接收者的代币余额
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        
        // 执行支持费用代币的交换
        _swapSupportingFeeOnTransferTokens(path, to);
        
        // 验证实际接收的代币数量满足最小要求
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    
    /// @notice 支持费用代币的精确输入代币数量交换 ETH
    /// @dev 专门处理有转账费用的代币，使用实际余额验证输出数量
    /// 
    /// 工作流程：
    /// 1. 验证路径以 WETH 结束
    /// 2. 从用户转移输入代币到第一个交易对
    /// 3. 执行支持费用代币的交换（输出到合约地址）
    /// 4. 获取合约中的 WETH 余额
    /// 5. 验证 WETH 余额满足最小要求
    /// 6. 将 WETH 解包为 ETH 并转移给用户
    /// 
    /// @param amountIn 输入代币数量
    /// @param amountOutMin 最小输出 ETH 数量（滑点保护）
    /// @param path 交换路径（必须以 WETH 结束）
    /// @param to 接收 ETH 的地址
    /// @param deadline 交易截止时间
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        // 验证路径以 WETH 结束
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        
        // 从用户转移输入代币到第一个交易对
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        
        // 执行支持费用代币的交换（输出到合约地址）
        _swapSupportingFeeOnTransferTokens(path, address(this));
        
        // 获取合约中的 WETH 余额
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        
        // 验证 WETH 余额满足最小要求
        require(amountOut >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        
        // 将 WETH 解包为 ETH 并转移给用户
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // ============ 库函数 ============
    
    /// @notice 计算代币 B 的等值数量
    /// @dev 基于储备量比例计算代币 B 的等值数量
    /// @param amountA 代币 A 的数量
    /// @param reserveA 代币 A 的储备量
    /// @param reserveB 代币 B 的储备量
    /// @return amountB 代币 B 的等值数量
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    /// @notice 计算输出代币数量
    /// @dev 基于恒定乘积公式计算输出代币数量
    /// @param amountIn 输入代币数量
    /// @param reserveIn 输入代币的储备量
    /// @param reserveOut 输出代币的储备量
    /// @return amountOut 输出代币数量
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @notice 计算输入代币数量
    /// @dev 基于恒定乘积公式计算输入代币数量
    /// @param amountOut 输出代币数量
    /// @param reserveIn 输入代币的储备量
    /// @param reserveOut 输出代币的储备量
    /// @return amountIn 输入代币数量
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    /// @notice 计算多跳路径的输出数量
    /// @dev 计算通过指定路径的每跳输出数量
    /// @param amountIn 输入代币数量
    /// @param path 交换路径（代币地址数组）
    /// @return amounts 每跳的输出数量数组
    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    /// @notice 计算多跳路径的输入数量
    /// @dev 计算通过指定路径的每跳输入数量
    /// @param amountOut 输出代币数量
    /// @param path 交换路径（代币地址数组）
    /// @return amounts 每跳的输入数量数组
    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
