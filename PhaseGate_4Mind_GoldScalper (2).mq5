//+------------------------------------------------------------------+
//|                    PhaseGate 4-Mind Gold Scalper                 |
//|                          MQL5 Expert Advisor                     |
//|                      XAUUSD M1 Scalping                          |
//+------------------------------------------------------------------+

#property description "4-Mind Gold Scalping EA - MarketDetector driven"
#property version     "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
// ENUMS
//+------------------------------------------------------------------+

enum MARKET_STATE
{
    STATE_STRONG_UPTREND   = 1,
    STATE_NEUTRAL_CHOPPY   = 2,
    STATE_STRONG_DOWNTREND = 3,
    STATE_HIGH_VOLATILITY  = 4
};

enum AutoCutMode { AUTOMATIC = 0, MANUAL = 1 };

enum LOG_CATEGORY
{
    LOG_INFO        = 0,
    LOG_OBSERVATION = 1,
    LOG_MEMORY      = 2,
    LOG_DETECTOR    = 3,
    LOG_MIND        = 4,
    LOG_TRADE       = 5,
    LOG_AUTOCUT     = 6,
    LOG_WARNING     = 7,
    LOG_ERROR       = 8
};

//+------------------------------------------------------------------+
// STRUCT: CandleRecord
//+------------------------------------------------------------------+
// Stores all fields for one closed M1 candle.
// Populated by ObservationEngine_ReadClosedCandles().

struct CandleRecord
{
    double open;
    double high;
    double low;
    double close;
    double body;
    double upperWick;
    double lowerWick;
    double range;
    int    direction;       // 1 = bullish, -1 = bearish, 0 = doji
    double bodyPct;
    double upperWickPct;
    double lowerWickPct;
};

//+------------------------------------------------------------------+
// STRUCT: ObservationAnalysis
//+------------------------------------------------------------------+
// Behavioural analysis derived from closed candle history.
// Observation only - no classification happens here.

struct ObservationAnalysis
{
    // Body behaviour
    bool   bodiesBecomingLarger;
    bool   bodiesBecomingSmaller;

    // Wick behaviour
    bool   upperWicksIncreasing;
    bool   upperWicksDecreasing;
    bool   lowerWicksIncreasing;
    bool   lowerWicksDecreasing;

    // Momentum behaviour (signed body: close - open)
    bool   momentumIncreasing;
    bool   momentumDecreasing;

    // Pressure behaviour
    bool   buyerPressureIncreasing;
    bool   buyerPressureDecreasing;
    bool   sellerPressureIncreasing;
    bool   sellerPressureDecreasing;

    // Range behaviour
    bool   rangeExpanding;
    bool   rangeContracting;

    // Market character
    bool   marketBecomingSmoother;
    bool   marketBecomingMoreRandom;
    bool   marketBecomingStronger;
    bool   marketBecomingWeaker;
    bool   marketBecomingAggressive;
    bool   marketSlowingDown;
    bool   marketSpeedingUp;

    // Direction behaviour
    bool   directionalConsistency;
    bool   directionalInstability;
    int    netDirection;        // 1 = net bullish, -1 = net bearish, 0 = mixed
    double directionStrength;   // 0.0 - 1.0

    // Quality scores (0.0 - 1.0)
    double candleQuality;       // avg body% across all candles
    double marketQuality;       // directional strength across all candles
    double volatilityQuality;   // body-to-range ratio across all candles
    double trendStability;      // how consistently directional the candles are
    double trendQuality;        // avg body% of candles matching net direction
    double observationConfidence; // ratio of history buffer filled
};

//+------------------------------------------------------------------+
// STRUCT: MarketObservation
//+------------------------------------------------------------------+
// Complete market snapshot captured every second.
// Fields in the "Market Memory" section are populated by MarketMemory_Update()
// after comparison with the previous observation, not by Capture().

struct MarketObservation
{
    // --- Timestamp ---
    datetime time;

    // --- Tick data ---
    double   bid;
    double   ask;
    double   spread;
    double   lastPrice;
    double   priceChange;       // Market Memory: lastPrice vs previous lastPrice

    // --- Running M1 candle - geometry ---
    double   open_M1;
    double   high_M1;
    double   low_M1;
    double   close_M1;          // = lastPrice (current price of running candle)
    double   body_M1;           // abs(close_M1 - open_M1)
    double   upperWick_M1;      // high_M1 - max(open_M1, close_M1)
    double   lowerWick_M1;      // min(open_M1, close_M1) - low_M1
    double   range_M1;          // high_M1 - low_M1
    double   bodyPct_M1;        // body_M1 / range_M1 * 100
    double   upperWickPct_M1;   // upperWick_M1 / range_M1 * 100
    double   lowerWickPct_M1;   // lowerWick_M1 / range_M1 * 100
    int      direction_M1;      // 1 = bullish, -1 = bearish, 0 = doji
    long     tickVolume;

    // --- Running M1 candle - quality (0.0 to 1.0) ---
    double   marketEnergy;          // directional energy of the candle (bodyPct / 100)
    double   candleQuality;         // directional clarity (bodyPct / 100)
    double   candleStability;       // wick symmetry (1 - |upperWickPct - lowerWickPct| / 100)
    double   candleAggressiveness;  // total wick exposure ((upperWickPct + lowerWickPct) / 100)
    double   candleSmoothness;      // how clean/smooth the candle is (bodyPct / 100)
    double   candleRandomness;      // opposite of smoothness (1 - smoothness)
    double   candleConfidence;      // combined signal reliability ((quality + stability) / 2)

    // --- Market Memory: derived vs previous observation ---
    double   momentum;          // = priceChange
    double   speed;             // abs(priceChange)
    double   buyerPressure;     // (close_M1 - low_M1) / range_M1
    double   sellerPressure;    // (high_M1 - close_M1) / range_M1
    bool     strengthening;     // dominant side gaining more control vs previous
    bool     weakening;         // dominant side losing control vs previous
    bool     expansion;         // range_M1 > previous range_M1
    bool     contraction;       // range_M1 < previous range_M1
    bool     acceleration;      // speed > previous speed
    bool     deceleration;      // speed < previous speed
};

//+------------------------------------------------------------------+
// GLOBAL VARIABLES
//+------------------------------------------------------------------+

CTrade        trade;
CPositionInfo positionInfo;

MARKET_STATE currentMarketState = STATE_NEUTRAL_CHOPPY;
double       detectorConfidence  = 0.0;   // 0.0 - 100.0 percent

// Market Memory core
MarketObservation currentObservation;
MarketObservation previousObservation;
bool              hasPreviousObservation = false;

// Closed candle storage (dynamic - sized from ObservationLength input in OnInit)
CandleRecord closedCandles[];
int          closedCandleCount = 0;

// Behavioural analysis (refreshed every second)
ObservationAnalysis currentAnalysis;

// Observation history circular buffer (dynamic - sized from MemoryLength input in OnInit)
MarketObservation observationHistory[];
int               historySize  = 0;
int               historyHead  = 0;    // next write position
int               historyCount = 0;    // entries currently filled

// History-derived averages (recomputed every second from buffer)
double historyAvgSpeed = 0.0;
double historyAvgRange = 0.0;

// Auto-cut state (shared between AutoCut module and Minds 2/4)
datetime autoExitTime   = 0;
bool     autoExitActive = false;
string   autoExitMind   = "";

//+------------------------------------------------------------------+
// INPUTS - MIND 1: STRONG UPTREND
//+------------------------------------------------------------------+

input group "=== MIND 1: STRONG UPTREND ===";
input bool   Mind1_Enable        = true;
input double Mind1_TP            = 5.00;
input double Mind1_SL            = 5.00;
input int    Mind1_MaxConcurrent = 1;

//+------------------------------------------------------------------+
// INPUTS - MIND 2: NEUTRAL / CHOPPY
//+------------------------------------------------------------------+

input group "=== MIND 2: NEUTRAL / CHOPPY ===";
input bool        Mind2_Enable        = true;
input double      Mind2_TP            = 2.10;
input double      Mind2_SL            = 7.50;
input bool        Mind2_EnableAutoCut = true;
input AutoCutMode Mind2_AutoCutMode   = AUTOMATIC;
input int         Mind2_AutoCutWait   = 15;

//+------------------------------------------------------------------+
// INPUTS - MIND 3: STRONG DOWNTREND
//+------------------------------------------------------------------+

input group "=== MIND 3: STRONG DOWNTREND ===";
input bool   Mind3_Enable        = true;
input double Mind3_TP            = 5.00;
input double Mind3_SL            = 5.00;
input int    Mind3_MaxConcurrent = 1;

//+------------------------------------------------------------------+
// INPUTS - MIND 4: HIGH VOLATILITY
//+------------------------------------------------------------------+

input group "=== MIND 4: HIGH VOLATILITY ===";
input bool        Mind4_Enable        = true;
input double      Mind4_TP            = 2.10;
input double      Mind4_SL            = 6.50;
input bool        Mind4_EnableAutoCut = true;
input AutoCutMode Mind4_AutoCutMode   = AUTOMATIC;
input int         Mind4_AutoCutWait   = 15;

//+------------------------------------------------------------------+
// INPUTS - OBSERVATION ENGINE
//+------------------------------------------------------------------+

input group "=== OBSERVATION ENGINE ===";
input int ObservationLength     = 35;   // Number of closed M1 candles to observe
input int ObservationUpdateTime = 1;    // Observation update interval (seconds)
input int MemoryLength          = 60;   // Number of past observations stored in history buffer

//+------------------------------------------------------------------+
// INPUTS - MARKET DETECTOR THRESHOLDS
//+------------------------------------------------------------------+

input group "=== MARKET DETECTOR THRESHOLDS ===";
input double RunningCandleWeight     = 0.50;  // Weight of running candle in state score
input double ClosedCandleWeight      = 0.50;  // Weight of closed candles in state score
input double BodyThreshold           = 0.00;  // Min body change to confirm growth/shrink
input double MomentumThreshold       = 0.00;  // Min momentum change to confirm shift
input double VolatilityThreshold     = 0.00;  // Min range change to confirm expansion/contraction
input double PressureThreshold       = 0.00;  // Min pressure change to confirm buyer/seller shift
input double DirectionThreshold      = 0.00;  // Min directional ratio to confirm consistency
input double ClassificationThreshold = 0.00;  // Min score required to accept a state change
input double ConfidenceThreshold     = 0.00;  // Min confidence required to log a state as certain

//+------------------------------------------------------------------+
// INPUTS - GENERAL SETTINGS
//+------------------------------------------------------------------+

input group "=== GENERAL SETTINGS ===";
input string TradingSymbol  = "XAUUSD";
input double LotSize        = 0.01;
input int    MagicNumber    = 20250707;
input bool   EnableLogging  = true;
input double PipDivisor     = 10.0;    // Converts dollar TP/SL to pip distance
input int    LogIntervalSec = 60;      // Periodic status log interval (seconds)

//+------------------------------------------------------------------+
// OnInit
//+------------------------------------------------------------------+

int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);

    ArrayResize(closedCandles,      ObservationLength);
    ArrayResize(observationHistory, MemoryLength);

    closedCandleCount  = 0;
    historySize        = MemoryLength;
    historyHead        = 0;
    historyCount       = 0;
    detectorConfidence = 0.0;
    historyAvgSpeed    = 0.0;
    historyAvgRange    = 0.0;

    InputManager();
    Logger(LOG_INFO, "EA initialized | Symbol: " + TradingSymbol +
           " | Lot: "       + DoubleToString(LotSize, 2) +
           " | ObsLength: " + IntegerToString(ObservationLength) +
           " | MemLength: " + IntegerToString(MemoryLength));
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
// OnDeinit
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
{
    Logger(LOG_INFO, "EA removed. Reason: " + IntegerToString(reason));
}

//+------------------------------------------------------------------+
// MODULE: InputManager
//+------------------------------------------------------------------+
// Validates all inputs at startup. Does not trade. Does not classify.

void InputManager()
{
    if(ObservationLength < 2)
        Logger(LOG_WARNING, "ObservationLength must be >= 2. Current: " + IntegerToString(ObservationLength));
    if(MemoryLength < 1)
        Logger(LOG_WARNING, "MemoryLength must be >= 1. Current: " + IntegerToString(MemoryLength));
    if(ObservationUpdateTime < 1)
        Logger(LOG_WARNING, "ObservationUpdateTime must be >= 1. Current: " + IntegerToString(ObservationUpdateTime));
    if(LotSize <= 0.0)
        Logger(LOG_WARNING, "LotSize must be > 0. Current: " + DoubleToString(LotSize, 4));
    if(PipDivisor <= 0.0)
        Logger(LOG_WARNING, "PipDivisor must be > 0. Current: " + DoubleToString(PipDivisor, 2));
    if(RunningCandleWeight < 0.0)
        Logger(LOG_WARNING, "RunningCandleWeight must be >= 0.");
    if(ClosedCandleWeight < 0.0)
        Logger(LOG_WARNING, "ClosedCandleWeight must be >= 0.");
    if(Mind1_TP <= 0.0 || Mind1_SL <= 0.0)
        Logger(LOG_WARNING, "Mind1 TP/SL must be > 0.");
    if(Mind2_TP <= 0.0 || Mind2_SL <= 0.0)
        Logger(LOG_WARNING, "Mind2 TP/SL must be > 0.");
    if(Mind3_TP <= 0.0 || Mind3_SL <= 0.0)
        Logger(LOG_WARNING, "Mind3 TP/SL must be > 0.");
    if(Mind4_TP <= 0.0 || Mind4_SL <= 0.0)
        Logger(LOG_WARNING, "Mind4 TP/SL must be > 0.");
}

//+------------------------------------------------------------------+
// MODULE: Logger
//+------------------------------------------------------------------+
// All logging passes through this single module.
// Every log includes: category, timestamp, current market state,
// detector confidence, and message.
// No other module calls Print() directly.

void Logger(LOG_CATEGORY category, string message)
{
    if(!EnableLogging) return;

    string prefix;
    switch(category)
    {
        case LOG_OBSERVATION: prefix = "[OBS]  "; break;
        case LOG_MEMORY:      prefix = "[MEM]  "; break;
        case LOG_DETECTOR:    prefix = "[DET]  "; break;
        case LOG_MIND:        prefix = "[MIND] "; break;
        case LOG_TRADE:       prefix = "[TRADE]"; break;
        case LOG_AUTOCUT:     prefix = "[CUT]  "; break;
        case LOG_WARNING:     prefix = "[WARN] "; break;
        case LOG_ERROR:       prefix = "[ERR]  "; break;
        default:              prefix = "[INFO] "; break;
    }

    Print(prefix + " | " +
          TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " | " +
          "State: "  + EnumToString(currentMarketState) + " | " +
          "Conf: "   + DoubleToString(detectorConfidence, 1) + "% | " +
          message);
}

//+------------------------------------------------------------------+
// OBSERVATION ENGINE
//+------------------------------------------------------------------+
// Watches the market only. Never classifies. Never trades.
// Updates every ObservationUpdateTime seconds.

void ObservationEngine_Capture(MarketObservation &obs)
{
    obs.time      = TimeCurrent();
    obs.bid       = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);
    obs.ask       = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
    obs.spread    = obs.ask - obs.bid;
    obs.lastPrice = (obs.bid + obs.ask) / 2.0;

    double openArr[], highArr[], lowArr[], closeArr[];
    long   volArr[];
    ArraySetAsSeries(openArr,  true);
    ArraySetAsSeries(highArr,  true);
    ArraySetAsSeries(lowArr,   true);
    ArraySetAsSeries(closeArr, true);
    ArraySetAsSeries(volArr,   true);

    // Current still-forming M1 candle - never wait for close
    CopyOpen(TradingSymbol,       PERIOD_M1, 0, 1, openArr);
    CopyHigh(TradingSymbol,       PERIOD_M1, 0, 1, highArr);
    CopyLow(TradingSymbol,        PERIOD_M1, 0, 1, lowArr);
    CopyClose(TradingSymbol,      PERIOD_M1, 0, 1, closeArr);
    CopyTickVolume(TradingSymbol, PERIOD_M1, 0, 1, volArr);

    obs.open_M1    = openArr[0];
    obs.high_M1    = highArr[0];
    obs.low_M1     = lowArr[0];
    obs.close_M1   = obs.lastPrice;   // running candle close = current price
    obs.range_M1   = obs.high_M1 - obs.low_M1;
    obs.tickVolume = volArr[0];

    // Body and wicks
    obs.body_M1      = MathAbs(obs.close_M1 - obs.open_M1);
    obs.upperWick_M1 = obs.high_M1 - MathMax(obs.open_M1, obs.close_M1);
    obs.lowerWick_M1 = MathMin(obs.open_M1, obs.close_M1) - obs.low_M1;

    // Direction
    if     (obs.close_M1 > obs.open_M1) obs.direction_M1 =  1;
    else if(obs.close_M1 < obs.open_M1) obs.direction_M1 = -1;
    else                                obs.direction_M1 =  0;

    if(obs.range_M1 > 0.0)
    {
        // Percentages
        obs.bodyPct_M1      = (obs.body_M1      / obs.range_M1) * 100.0;
        obs.upperWickPct_M1 = (obs.upperWick_M1 / obs.range_M1) * 100.0;
        obs.lowerWickPct_M1 = (obs.lowerWick_M1 / obs.range_M1) * 100.0;

        // Buyer/seller pressure: position of close within candle range
        obs.buyerPressure  = (obs.close_M1 - obs.low_M1)   / obs.range_M1;
        obs.sellerPressure = (obs.high_M1  - obs.close_M1) / obs.range_M1;

        // Running candle quality metrics (0.0 to 1.0)
        obs.marketEnergy        = obs.bodyPct_M1 / 100.0;
        obs.candleQuality       = obs.bodyPct_M1 / 100.0;
        obs.candleStability     = 1.0 - (MathAbs(obs.upperWickPct_M1 - obs.lowerWickPct_M1) / 100.0);
        obs.candleAggressiveness = (obs.upperWickPct_M1 + obs.lowerWickPct_M1) / 100.0;
        obs.candleSmoothness    = obs.bodyPct_M1 / 100.0;
        obs.candleRandomness    = 1.0 - obs.candleSmoothness;
        obs.candleConfidence    = (obs.candleQuality + obs.candleStability) / 2.0;
    }
    else
    {
        obs.bodyPct_M1       = 0.0;
        obs.upperWickPct_M1  = 0.0;
        obs.lowerWickPct_M1  = 0.0;
        obs.buyerPressure    = 0.0;
        obs.sellerPressure   = 0.0;
        obs.marketEnergy     = 0.0;
        obs.candleQuality    = 0.0;
        obs.candleStability  = 0.0;
        obs.candleAggressiveness = 0.0;
        obs.candleSmoothness = 0.0;
        obs.candleRandomness = 0.0;
        obs.candleConfidence = 0.0;
    }

    // Comparison fields - populated by Market Memory after comparing to previous
    obs.priceChange   = 0.0;
    obs.momentum      = 0.0;
    obs.speed         = 0.0;
    obs.expansion     = false;
    obs.contraction   = false;
    obs.acceleration  = false;
    obs.deceleration  = false;
    obs.strengthening = false;
    obs.weakening     = false;

    Logger(LOG_OBSERVATION,
           "Captured | Price: "   + DoubleToString(obs.lastPrice, 5)     +
           " | Body%: "           + DoubleToString(obs.bodyPct_M1, 1)    +
           " | Dir: "             + IntegerToString(obs.direction_M1)     +
           " | Energy: "          + DoubleToString(obs.marketEnergy, 3)  +
           " | Quality: "         + DoubleToString(obs.candleQuality, 3) +
           " | Conf: "            + DoubleToString(obs.candleConfidence, 3));
}

void ObservationEngine_ReadClosedCandles()
{
    double openArr[], highArr[], lowArr[], closeArr[];
    ArraySetAsSeries(openArr,  true);
    ArraySetAsSeries(highArr,  true);
    ArraySetAsSeries(lowArr,   true);
    ArraySetAsSeries(closeArr, true);

    // Index 1 = most recently closed candle; index 0 = still-forming (skipped)
    if(CopyOpen(TradingSymbol,  PERIOD_M1, 1, ObservationLength, openArr)  < ObservationLength) return;
    if(CopyHigh(TradingSymbol,  PERIOD_M1, 1, ObservationLength, highArr)  < ObservationLength) return;
    if(CopyLow(TradingSymbol,   PERIOD_M1, 1, ObservationLength, lowArr)   < ObservationLength) return;
    if(CopyClose(TradingSymbol, PERIOD_M1, 1, ObservationLength, closeArr) < ObservationLength) return;

    closedCandleCount = ObservationLength;

    for(int i = 0; i < ObservationLength; i++)
    {
        CandleRecord &c = closedCandles[i];
        c.open  = openArr[i];
        c.high  = highArr[i];
        c.low   = lowArr[i];
        c.close = closeArr[i];

        c.range     = c.high - c.low;
        c.body      = MathAbs(c.close - c.open);
        c.upperWick = c.high - MathMax(c.open, c.close);
        c.lowerWick = MathMin(c.open, c.close) - c.low;

        if     (c.close > c.open) c.direction = 1;
        else if(c.close < c.open) c.direction = -1;
        else                      c.direction = 0;

        if(c.range > 0.0)
        {
            c.bodyPct      = (c.body      / c.range) * 100.0;
            c.upperWickPct = (c.upperWick / c.range) * 100.0;
            c.lowerWickPct = (c.lowerWick / c.range) * 100.0;
        }
        else
        {
            c.bodyPct      = 0.0;
            c.upperWickPct = 0.0;
            c.lowerWickPct = 0.0;
        }
    }
}

void ObservationEngine_AnalyzeHistory()
{
    if(closedCandleCount < 2) return;

    int recentCount  = closedCandleCount / 2;
    int earlierCount = closedCandleCount - recentCount;

    // --- Accumulators: recent half (indices 0..recentCount-1, most recent first) ---
    double sumBodyRecent       = 0.0;
    double sumRangeRecent      = 0.0;
    double sumUWRecent         = 0.0;   // upper wick
    double sumLWRecent         = 0.0;   // lower wick
    double sumBuyPressRecent   = 0.0;   // buyer pressure per candle
    double sumBodyPctRecent    = 0.0;
    double sumSignedMomRecent  = 0.0;   // signed: close - open
    int    dirSumRecent        = 0;

    // --- Accumulators: earlier half (indices recentCount..closedCandleCount-1) ---
    double sumBodyEarlier      = 0.0;
    double sumRangeEarlier     = 0.0;
    double sumUWEarlier        = 0.0;
    double sumLWEarlier        = 0.0;
    double sumBuyPressEarlier  = 0.0;
    double sumBodyPctEarlier   = 0.0;
    double sumSignedMomEarlier = 0.0;
    int    dirSumEarlier       = 0;

    for(int i = 0; i < recentCount; i++)
    {
        CandleRecord &c = closedCandles[i];
        sumBodyRecent      += c.body;
        sumRangeRecent     += c.range;
        sumUWRecent        += c.upperWick;
        sumLWRecent        += c.lowerWick;
        sumBodyPctRecent   += c.bodyPct;
        sumSignedMomRecent += (c.close - c.open);
        dirSumRecent       += c.direction;
        if(c.range > 0.0) sumBuyPressRecent += (c.close - c.low) / c.range;
    }

    for(int i = recentCount; i < closedCandleCount; i++)
    {
        CandleRecord &c = closedCandles[i];
        sumBodyEarlier      += c.body;
        sumRangeEarlier     += c.range;
        sumUWEarlier        += c.upperWick;
        sumLWEarlier        += c.lowerWick;
        sumBodyPctEarlier   += c.bodyPct;
        sumSignedMomEarlier += (c.close - c.open);
        dirSumEarlier       += c.direction;
        if(c.range > 0.0) sumBuyPressEarlier += (c.close - c.low) / c.range;
    }

    // All-candle totals (derived from both halves - avoids a third loop)
    double sumBodyPctAll = sumBodyPctRecent + sumBodyPctEarlier;
    double sumRangeAll   = sumRangeRecent   + sumRangeEarlier;
    double sumBodyAll    = sumBodyRecent    + sumBodyEarlier;
    int    dirSumAll     = dirSumRecent     + dirSumEarlier;

    // --- Averages ---
    double avgBodyRecent    = sumBodyRecent    / recentCount;
    double avgBodyEarlier   = sumBodyEarlier   / earlierCount;
    double avgRangeRecent   = sumRangeRecent   / recentCount;
    double avgRangeEarlier  = sumRangeEarlier  / earlierCount;
    double avgUWRecent      = sumUWRecent      / recentCount;
    double avgUWEarlier     = sumUWEarlier     / earlierCount;
    double avgLWRecent      = sumLWRecent      / recentCount;
    double avgLWEarlier     = sumLWEarlier     / earlierCount;
    double avgBPRecent      = sumBuyPressRecent  / recentCount;
    double avgBPEarlier     = sumBuyPressEarlier / earlierCount;
    double avgBPctRecent    = sumBodyPctRecent   / recentCount;
    double avgBPctEarlier   = sumBodyPctEarlier  / earlierCount;
    double avgSMomRecent    = sumSignedMomRecent  / recentCount;
    double avgSMomEarlier   = sumSignedMomEarlier / earlierCount;
    double avgBodyPctAll    = sumBodyPctAll / closedCandleCount;
    double avgRangeAll      = sumRangeAll   / closedCandleCount;

    // --- Body behaviour ---
    currentAnalysis.bodiesBecomingLarger  = (avgBodyRecent  > avgBodyEarlier  + BodyThreshold);
    currentAnalysis.bodiesBecomingSmaller = (avgBodyEarlier > avgBodyRecent   + BodyThreshold);

    // --- Range behaviour ---
    currentAnalysis.rangeExpanding   = (avgRangeRecent  > avgRangeEarlier + VolatilityThreshold);
    currentAnalysis.rangeContracting = (avgRangeEarlier > avgRangeRecent  + VolatilityThreshold);

    // --- Wick behaviour ---
    currentAnalysis.upperWicksIncreasing = (avgUWRecent  > avgUWEarlier + BodyThreshold);
    currentAnalysis.upperWicksDecreasing = (avgUWEarlier > avgUWRecent  + BodyThreshold);
    currentAnalysis.lowerWicksIncreasing = (avgLWRecent  > avgLWEarlier + BodyThreshold);
    currentAnalysis.lowerWicksDecreasing = (avgLWEarlier > avgLWRecent  + BodyThreshold);

    // --- Pressure behaviour ---
    // buyer pressure increasing = avg (close-low)/range is rising
    currentAnalysis.buyerPressureIncreasing  = (avgBPRecent  > avgBPEarlier + PressureThreshold);
    currentAnalysis.buyerPressureDecreasing  = (avgBPEarlier > avgBPRecent  + PressureThreshold);
    // seller pressure is inverse of buyer pressure
    currentAnalysis.sellerPressureIncreasing = (avgBPEarlier > avgBPRecent  + PressureThreshold);
    currentAnalysis.sellerPressureDecreasing = (avgBPRecent  > avgBPEarlier + PressureThreshold);

    // --- Momentum behaviour (signed body: positive = bullish force) ---
    currentAnalysis.momentumIncreasing = (avgSMomRecent  > avgSMomEarlier + MomentumThreshold);
    currentAnalysis.momentumDecreasing = (avgSMomEarlier > avgSMomRecent  + MomentumThreshold);

    // --- Direction behaviour ---
    double dirRatioRecent = (recentCount > 0)
        ? MathAbs((double)dirSumRecent) / recentCount
        : 0.0;
    currentAnalysis.directionalConsistency = (dirRatioRecent >= DirectionThreshold);
    currentAnalysis.directionalInstability = !currentAnalysis.directionalConsistency;
    currentAnalysis.netDirection    = (dirSumAll > 0) ? 1 : (dirSumAll < 0) ? -1 : 0;
    currentAnalysis.directionStrength = MathAbs((double)dirSumAll) / closedCandleCount;

    // --- Market character (computed after direction is known) ---
    // Smoother: body% rising, meaning cleaner directional moves
    currentAnalysis.marketBecomingSmoother   = (avgBPctRecent > avgBPctEarlier + BodyThreshold);
    // More random: body% falling, wicks dominating
    currentAnalysis.marketBecomingMoreRandom = (avgBPctEarlier > avgBPctRecent + BodyThreshold);
    // Aggressive: range expanding AND wicks growing (rejections)
    currentAnalysis.marketBecomingAggressive = (currentAnalysis.rangeExpanding &&
        (currentAnalysis.upperWicksIncreasing || currentAnalysis.lowerWicksIncreasing));
    // Slowing: range contracting AND bodies shrinking
    currentAnalysis.marketSlowingDown = (currentAnalysis.rangeContracting &&
                                         currentAnalysis.bodiesBecomingSmaller);
    // Speeding: range expanding AND bodies growing
    currentAnalysis.marketSpeedingUp  = (currentAnalysis.rangeExpanding &&
                                          currentAnalysis.bodiesBecomingLarger);
    // Stronger: directional AND bodies growing
    currentAnalysis.marketBecomingStronger = (currentAnalysis.bodiesBecomingLarger &&
                                               currentAnalysis.directionalConsistency);
    // Weaker: bodies shrinking AND wicks growing
    currentAnalysis.marketBecomingWeaker = (currentAnalysis.bodiesBecomingSmaller &&
        (currentAnalysis.upperWicksIncreasing || currentAnalysis.lowerWicksIncreasing));

    // --- Quality scores ---
    // Candle quality: average body% across all 35 candles (0-1)
    currentAnalysis.candleQuality = avgBodyPctAll / 100.0;

    // Market quality: directional strength across all 35 candles (0-1)
    currentAnalysis.marketQuality = currentAnalysis.directionStrength;

    // Volatility quality: how much of range is body vs wicks (1 = all body, 0 = all wicks)
    currentAnalysis.volatilityQuality = (avgRangeAll > 0.0)
        ? MathMin(1.0, (sumBodyAll / closedCandleCount) / avgRangeAll)
        : 0.0;

    // Trend stability: same as direction strength (consistent direction = stable trend)
    currentAnalysis.trendStability = currentAnalysis.directionStrength;

    // Trend quality: avg body% only of candles matching the net direction
    double sumTrendBodyPct = 0.0;
    int    trendCount      = 0;
    if(currentAnalysis.netDirection != 0)
    {
        for(int i = 0; i < closedCandleCount; i++)
        {
            if(closedCandles[i].direction == currentAnalysis.netDirection)
            {
                sumTrendBodyPct += closedCandles[i].bodyPct;
                trendCount++;
            }
        }
    }
    currentAnalysis.trendQuality = (trendCount > 0) ? sumTrendBodyPct / trendCount / 100.0 : 0.0;

    // Observation confidence: ratio of history buffer filled (0-1)
    currentAnalysis.observationConfidence = (historySize > 0)
        ? MathMin(1.0, (double)historyCount / historySize)
        : 0.0;

    Logger(LOG_OBSERVATION,
           "Analysis | BodyGrow: "    + (currentAnalysis.bodiesBecomingLarger  ? "Y" : "N") +
           " | RangeExp: "            + (currentAnalysis.rangeExpanding          ? "Y" : "N") +
           " | MomUp: "               + (currentAnalysis.momentumIncreasing      ? "Y" : "N") +
           " | NetDir: "              + IntegerToString(currentAnalysis.netDirection) +
           " | DirStr: "              + DoubleToString(currentAnalysis.directionStrength, 2) +
           " | CandleQ: "             + DoubleToString(currentAnalysis.candleQuality, 2) +
           " | TrendQ: "              + DoubleToString(currentAnalysis.trendQuality, 2) +
           " | ObsConf: "             + DoubleToString(currentAnalysis.observationConfidence, 2));
}

bool ObservationEngine_IsMarketMovingSmoothly(const MarketObservation &current,
                                               const MarketObservation &previous,
                                               bool memoryReady)
{
    if(!memoryReady) return false;
    // Smooth: speed falling, bodies growing, consistent direction, low randomness
    bool speedFalling  = (current.speed <= previous.speed);
    bool bodiesGrowing = currentAnalysis.bodiesBecomingLarger;
    bool consistent    = currentAnalysis.directionalConsistency;
    bool lowRandom     = !currentAnalysis.marketBecomingMoreRandom;
    return speedFalling && bodiesGrowing && consistent && lowRandom;
}

bool ObservationEngine_IsMarketBecomingAggressive(const MarketObservation &current,
                                                    const MarketObservation &previous,
                                                    bool memoryReady)
{
    if(!memoryReady) return false;
    // Aggressive: speed rising above previous, range expanding, wicks growing
    bool speedRising  = (current.speed > previous.speed + MomentumThreshold);
    bool rangeGrowing = currentAnalysis.rangeExpanding;
    bool wicksGrowing = (currentAnalysis.upperWicksIncreasing || currentAnalysis.lowerWicksIncreasing);
    return speedRising && rangeGrowing && wicksGrowing;
}

bool ObservationEngine_IsMarketSlowingDown(const MarketObservation &current,
                                            const MarketObservation &previous,
                                            bool memoryReady)
{
    if(!memoryReady) return false;
    // Slowing: speed falling, range contracting, bodies shrinking
    bool speedFalling    = (current.speed < previous.speed);
    bool rangeShrinking  = currentAnalysis.rangeContracting;
    bool bodiesShrinking = currentAnalysis.bodiesBecomingSmaller;
    return speedFalling && rangeShrinking && bodiesShrinking;
}

//+------------------------------------------------------------------+
// MARKET MEMORY
//+------------------------------------------------------------------+
// Remembers all observations. Compares current vs previous and vs history.
// Stores history in circular buffer. Never loses past observations.

void MarketMemory_Update()
{
    MarketObservation newObs;
    ObservationEngine_Capture(newObs);

    if(hasPreviousObservation)
    {
        // Price movement
        newObs.priceChange = newObs.lastPrice - previousObservation.lastPrice;
        newObs.momentum    = newObs.priceChange;
        newObs.speed       = MathAbs(newObs.priceChange);

        // Range change vs previous second
        newObs.expansion   = (newObs.range_M1 > previousObservation.range_M1);
        newObs.contraction = (newObs.range_M1 < previousObservation.range_M1);

        // Speed change vs previous second
        newObs.acceleration = (newObs.speed > previousObservation.speed);
        newObs.deceleration = (newObs.speed < previousObservation.speed);

        // Strengthening/weakening: dominant side gaining or losing control
        if(newObs.direction_M1 == 1)
        {
            newObs.strengthening = (newObs.buyerPressure  > previousObservation.buyerPressure  + PressureThreshold);
            newObs.weakening     = (newObs.buyerPressure  < previousObservation.buyerPressure  - PressureThreshold);
        }
        else if(newObs.direction_M1 == -1)
        {
            newObs.strengthening = (newObs.sellerPressure > previousObservation.sellerPressure + PressureThreshold);
            newObs.weakening     = (newObs.sellerPressure < previousObservation.sellerPressure - PressureThreshold);
        }
        else
        {
            newObs.strengthening = false;
            newObs.weakening     = false;
        }
    }

    // Read and analyse closed candle history
    ObservationEngine_ReadClosedCandles();
    ObservationEngine_AnalyzeHistory();

    // Store in circular history buffer
    if(historySize > 0)
    {
        observationHistory[historyHead] = newObs;
        historyHead = (historyHead + 1) % historySize;
        if(historyCount < historySize) historyCount++;
    }

    // Recompute history averages from buffer (used by MarketDetector scoring)
    if(historyCount > 0)
    {
        double sumSpeed = 0.0, sumRange = 0.0;
        for(int i = 0; i < historyCount; i++)
        {
            int idx = (historyHead - 1 - i + historySize) % historySize;
            sumSpeed += observationHistory[idx].speed;
            sumRange += observationHistory[idx].range_M1;
        }
        historyAvgSpeed = sumSpeed / historyCount;
        historyAvgRange = sumRange / historyCount;
    }

    // Shift memory forward
    previousObservation    = currentObservation;
    currentObservation     = newObs;
    hasPreviousObservation = true;

    Logger(LOG_MEMORY,
           "Updated | Price: "   + DoubleToString(newObs.lastPrice, 5) +
           " | Speed: "          + DoubleToString(newObs.speed, 5)     +
           " | AvgSpeed: "       + DoubleToString(historyAvgSpeed, 5)  +
           " | Expand: "         + (newObs.expansion     ? "Y" : "N")  +
           " | Accel: "          + (newObs.acceleration  ? "Y" : "N")  +
           " | Strong: "         + (newObs.strengthening ? "Y" : "N")  +
           " | Weak: "           + (newObs.weakening     ? "Y" : "N")  +
           " | Hist: "           + IntegerToString(historyCount));
}

//+------------------------------------------------------------------+
// MODULE: MarketDetector
//+------------------------------------------------------------------+
// Completely independent. Does NOT trade.
// Receives data from Observation Engine and Market Memory only.
// Returns exactly ONE MARKET_STATE and updates detectorConfidence.

// Internal scoring helpers - not modules, only called by MarketDetector.

double Detector_ScoreUptrend(bool isSmooth)
{
    double rs = 0.0;   // running candle score (4 signals)
    double cs = 0.0;   // closed candle score  (8 signals)

    if(currentObservation.direction_M1 == 1)               rs += 1.0;
    if(currentObservation.buyerPressure > PressureThreshold) rs += 1.0;
    if(currentObservation.acceleration)                     rs += 1.0;
    if(currentObservation.expansion)                        rs += 1.0;

    if(currentAnalysis.netDirection == 1)                   cs += 1.0;
    if(currentAnalysis.directionalConsistency)              cs += 1.0;
    if(currentAnalysis.bodiesBecomingLarger)                cs += 1.0;
    if(currentAnalysis.buyerPressureIncreasing)             cs += 1.0;
    if(currentAnalysis.marketBecomingStronger)              cs += 1.0;
    if(currentAnalysis.rangeExpanding)                      cs += 1.0;
    if(!currentAnalysis.sellerPressureIncreasing)           cs += 1.0;
    if(isSmooth)                                            cs += 1.0;

    return (rs / 4.0) * RunningCandleWeight + (cs / 8.0) * ClosedCandleWeight;
}

double Detector_ScoreDowntrend(bool isSmooth)
{
    double rs = 0.0;   // running candle score (4 signals)
    double cs = 0.0;   // closed candle score  (8 signals)

    if(currentObservation.direction_M1 == -1)               rs += 1.0;
    if(currentObservation.sellerPressure > PressureThreshold) rs += 1.0;
    if(currentObservation.acceleration)                      rs += 1.0;
    if(currentObservation.expansion)                         rs += 1.0;

    if(currentAnalysis.netDirection == -1)                   cs += 1.0;
    if(currentAnalysis.directionalConsistency)               cs += 1.0;
    if(currentAnalysis.bodiesBecomingLarger)                 cs += 1.0;
    if(currentAnalysis.sellerPressureIncreasing)             cs += 1.0;
    if(currentAnalysis.marketBecomingStronger)               cs += 1.0;
    if(currentAnalysis.rangeExpanding)                       cs += 1.0;
    if(!currentAnalysis.buyerPressureIncreasing)             cs += 1.0;
    if(isSmooth)                                             cs += 1.0;

    return (rs / 4.0) * RunningCandleWeight + (cs / 8.0) * ClosedCandleWeight;
}

double Detector_ScoreChoppy(bool isSlowing)
{
    double rs = 0.0;   // running candle score (4 signals)
    double cs = 0.0;   // closed candle score  (7 signals)

    if(currentObservation.direction_M1 == 0)               rs += 1.0;
    if(currentObservation.deceleration)                    rs += 1.0;
    if(currentObservation.contraction)                     rs += 1.0;
    if(currentObservation.speed < historyAvgSpeed)         rs += 1.0;

    if(currentAnalysis.directionalInstability)             cs += 1.0;
    if(currentAnalysis.bodiesBecomingSmaller)              cs += 1.0;
    if(currentAnalysis.rangeContracting)                   cs += 1.0;
    if(currentAnalysis.marketSlowingDown)                  cs += 1.0;
    if(!currentAnalysis.rangeExpanding)                    cs += 1.0;
    if(!currentAnalysis.marketBecomingStronger)            cs += 1.0;
    if(isSlowing)                                          cs += 1.0;

    return (rs / 4.0) * RunningCandleWeight + (cs / 7.0) * ClosedCandleWeight;
}

double Detector_ScoreVolatility(bool isAggressive)
{
    double rs = 0.0;   // running candle score (4 signals)
    double cs = 0.0;   // closed candle score  (7 signals)

    if(currentObservation.expansion)                                           rs += 1.0;
    if(currentObservation.acceleration)                                        rs += 1.0;
    if(currentObservation.speed > historyAvgSpeed + MomentumThreshold)        rs += 1.0;
    if(currentObservation.candleAggressiveness > VolatilityThreshold)         rs += 1.0;

    if(currentAnalysis.rangeExpanding)                                         cs += 1.0;
    if(currentAnalysis.marketBecomingAggressive)                               cs += 1.0;
    if(currentAnalysis.marketSpeedingUp)                                       cs += 1.0;
    if(currentAnalysis.directionalInstability)                                 cs += 1.0;
    if(currentAnalysis.upperWicksIncreasing || currentAnalysis.lowerWicksIncreasing) cs += 1.0;
    if(!currentAnalysis.marketSlowingDown)                                     cs += 1.0;
    if(isAggressive)                                                           cs += 1.0;

    return (rs / 4.0) * RunningCandleWeight + (cs / 7.0) * ClosedCandleWeight;
}

MARKET_STATE MarketDetector(const MarketObservation &current,
                             const MarketObservation &previous,
                             bool memoryReady)
{
    if(!memoryReady)
        return currentMarketState;

    // Derive observation booleans from the Observation Engine
    bool smooth     = ObservationEngine_IsMarketMovingSmoothly(current, previous, memoryReady);
    bool aggressive = ObservationEngine_IsMarketBecomingAggressive(current, previous, memoryReady);
    bool slowing    = ObservationEngine_IsMarketSlowingDown(current, previous, memoryReady);

    // Score each state using only observation data
    double scoreUp   = Detector_ScoreUptrend(smooth);
    double scoreDown = Detector_ScoreDowntrend(smooth);
    double scoreChop = Detector_ScoreChoppy(slowing);
    double scoreVol  = Detector_ScoreVolatility(aggressive);

    // Find the highest score
    double maxScore = MathMax(MathMax(scoreUp, scoreDown), MathMax(scoreChop, scoreVol));

    // Find second-highest score for confidence margin calculation
    double scores[4];
    scores[0] = scoreUp;
    scores[1] = scoreDown;
    scores[2] = scoreChop;
    scores[3] = scoreVol;

    double secondMax = 0.0;
    for(int i = 0; i < 4; i++)
        if(scores[i] < maxScore && scores[i] > secondMax) secondMax = scores[i];

    // Confidence = margin between winner and runner-up, scaled by observation fill
    double margin = (maxScore > 0.0) ? (maxScore - secondMax) / maxScore : 0.0;
    detectorConfidence = margin * currentAnalysis.observationConfidence * 100.0;

    // State change only if winning score clears the classification threshold
    MARKET_STATE newState = currentMarketState;
    if(maxScore >= ClassificationThreshold)
    {
        if     (scoreUp   > scoreDown && scoreUp   > scoreChop && scoreUp   > scoreVol) newState = STATE_STRONG_UPTREND;
        else if(scoreDown > scoreUp   && scoreDown > scoreChop && scoreDown > scoreVol) newState = STATE_STRONG_DOWNTREND;
        else if(scoreVol  > scoreUp   && scoreVol  > scoreChop && scoreVol  > scoreDown) newState = STATE_HIGH_VOLATILITY;
        else if(scoreChop > scoreUp   && scoreChop > scoreDown && scoreChop > scoreVol) newState = STATE_NEUTRAL_CHOPPY;
        // Ties: keep current state (no change)
    }

    bool stateChanged = (newState != currentMarketState);
    if(stateChanged)
        Logger(LOG_DETECTOR,
               "STATE CHANGED: " + EnumToString(currentMarketState) + " -> " + EnumToString(newState) +
               " | Up=" + DoubleToString(scoreUp, 3)   +
               " Dn="   + DoubleToString(scoreDown, 3) +
               " Ch="   + DoubleToString(scoreChop, 3) +
               " Vo="   + DoubleToString(scoreVol, 3));
    else
        Logger(LOG_DETECTOR,
               "State: " + EnumToString(newState) +
               " | Up=" + DoubleToString(scoreUp, 3)   +
               " Dn="   + DoubleToString(scoreDown, 3) +
               " Ch="   + DoubleToString(scoreChop, 3) +
               " Vo="   + DoubleToString(scoreVol, 3));

    return newState;
}

//+------------------------------------------------------------------+
// MODULE: TradeManager
//+------------------------------------------------------------------+
// Centralised trade utility. No Mind logic lives here.

int TradeManager_CountOpen()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(positionInfo.SelectByIndex(i))
            if(positionInfo.Symbol() == TradingSymbol)
                count++;
    }
    return count;
}

bool TradeManager_HasOpenByComment(string commentFilter)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(positionInfo.SelectByIndex(i))
            if(positionInfo.Symbol() == TradingSymbol &&
               StringFind(positionInfo.Comment(), commentFilter) >= 0)
                return true;
    }
    return false;
}

void TradeManager_CloseByComment(string commentFilter)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(positionInfo.SelectByIndex(i))
            if(positionInfo.Symbol() == TradingSymbol &&
               StringFind(positionInfo.Comment(), commentFilter) >= 0)
            {
                ulong ticket = positionInfo.Ticket();
                trade.PositionClose(ticket);
                Logger(LOG_TRADE, "Closed | Comment: " + commentFilter +
                       " | Ticket: " + IntegerToString((int)ticket));
            }
    }
}

void TradeManager()
{
    // Reserved for future centralised trade management logic
}

//+------------------------------------------------------------------+
// MODULE: AutoCut
//+------------------------------------------------------------------+
// Handles timed auto-exit for Minds that request it (Mind2, Mind4).
// No other module may implement auto-exit logic directly.

void AutoCut()
{
    if(!autoExitActive) return;

    if(TimeCurrent() >= autoExitTime)
    {
        TradeManager_CloseByComment(autoExitMind);
        Logger(LOG_AUTOCUT, "AutoCut executed for " + autoExitMind);
        autoExitActive = false;
        autoExitMind   = "";
    }
}

//+------------------------------------------------------------------+
// PLACEHOLDER FUNCTIONS
// These five functions remain as TODO until strategy rules are defined.
//+------------------------------------------------------------------+

bool FindBuyOpportunity()
{
    // TODO
    return false;
}

bool FindSellOpportunity()
{
    // TODO
    return false;
}

double GetResistance()
{
    // TODO
    return 0.0;
}

double GetSupport()
{
    // TODO
    return 0.0;
}

bool FindOppositeTrade()
{
    // TODO
    return false;
}

//+------------------------------------------------------------------+
// MODULE: Mind1 - STRONG UPTREND
//+------------------------------------------------------------------+
// Only active when MarketDetector returns STATE_STRONG_UPTREND.
// Strategy preserved exactly as defined.

void Mind1()
{
    if(!Mind1_Enable) return;
    if(TradeManager_CountOpen() >= Mind1_MaxConcurrent) return;

    double ask   = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(TradingSymbol, SYMBOL_POINT);
    double tp    = ask + (Mind1_TP / PipDivisor) * point;
    double sl    = ask - (Mind1_SL / PipDivisor) * point;

    // TODO: define Buy Opportunity condition before executing
    trade.Buy(LotSize, TradingSymbol, ask, sl, tp, "Mind1_StrongUptrend");
    Logger(LOG_TRADE, "Mind1 BUY | Ask: " + DoubleToString(ask, 5) +
           " | TP: " + DoubleToString(tp, 5) +
           " | SL: " + DoubleToString(sl, 5));
}

//+------------------------------------------------------------------+
// MODULE: Mind2 - NEUTRAL / CHOPPY
//+------------------------------------------------------------------+
// Only active when MarketDetector returns STATE_NEUTRAL_CHOPPY.
// Strategy preserved exactly as defined.

void Mind2()
{
    if(!Mind2_Enable) return;
    if(TradeManager_HasOpenByComment("Mind2")) return;

    double ask   = SymbolInfoDouble(TradingSymbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(TradingSymbol, SYMBOL_POINT);
    double tp    = ask + (Mind2_TP / PipDivisor) * point;
    double sl    = ask - (Mind2_SL / PipDivisor) * point;

    // TODO: define Buy Opportunity condition before executing
    trade.Buy(LotSize, TradingSymbol, ask, sl, tp, "Mind2_Choppy");

    if(Mind2_EnableAutoCut)
    {
        autoExitActive = true;
        autoExitTime   = TimeCurrent() + Mind2_AutoCutWait;
        autoExitMind   = "Mind2";
    }

    Logger(LOG_TRADE, "Mind2 opened | Ask: " + DoubleToString(ask, 5) +
           " | AutoCut in: " + IntegerToString(Mind2_AutoCutWait) + "s");
}

//+------------------------------------------------------------------+
// MODULE: Mind3 - STRONG DOWNTREND
//+------------------------------------------------------------------+
// Only active when MarketDetector returns STATE_STRONG_DOWNTREND.
// Strategy preserved exactly as defined.

void Mind3()
{
    if(!Mind3_Enable) return;
    if(TradeManager_CountOpen() >= Mind3_MaxConcurrent) return;

    double bid   = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);
    double point = SymbolInfoDouble(TradingSymbol, SYMBOL_POINT);
    double tp    = bid - (Mind3_TP / PipDivisor) * point;
    double sl    = bid + (Mind3_SL / PipDivisor) * point;

    // TODO: define Sell Opportunity condition before executing
    trade.Sell(LotSize, TradingSymbol, bid, sl, tp, "Mind3_StrongDowntrend");
    Logger(LOG_TRADE, "Mind3 SELL | Bid: " + DoubleToString(bid, 5) +
           " | TP: " + DoubleToString(tp, 5) +
           " | SL: " + DoubleToString(sl, 5));
}

//+------------------------------------------------------------------+
// MODULE: Mind4 - HIGH VOLATILITY
//+------------------------------------------------------------------+
// Only active when MarketDetector returns STATE_HIGH_VOLATILITY.
// Strategy preserved exactly as defined.

void Mind4()
{
    if(!Mind4_Enable) return;
    if(TradeManager_HasOpenByComment("Mind4")) return;

    double bid   = SymbolInfoDouble(TradingSymbol, SYMBOL_BID);
    double point = SymbolInfoDouble(TradingSymbol, SYMBOL_POINT);
    double tp    = bid - (Mind4_TP / PipDivisor) * point;
    double sl    = bid + (Mind4_SL / PipDivisor) * point;

    // TODO: define Sell Opportunity condition before executing
    trade.Sell(LotSize, TradingSymbol, bid, sl, tp, "Mind4_HighVolatility");

    if(Mind4_EnableAutoCut)
    {
        autoExitActive = true;
        autoExitTime   = TimeCurrent() + Mind4_AutoCutWait;
        autoExitMind   = "Mind4";
    }

    Logger(LOG_TRADE, "Mind4 opened | Bid: " + DoubleToString(bid, 5) +
           " | AutoCut in: " + IntegerToString(Mind4_AutoCutWait) + "s");
}

//+------------------------------------------------------------------+
// MAIN LOOP - OnTick
//+------------------------------------------------------------------+

void OnTick()
{
    datetime currentTime = TimeCurrent();
    static datetime lastTickTime = 0;

    // Respect ObservationUpdateTime input - do not update faster than configured
    if(currentTime - lastTickTime < (datetime)ObservationUpdateTime) return;
    lastTickTime = currentTime;

    // STEP 1: Observe the market and update Market Memory (current vs previous vs history)
    MarketMemory_Update();

    // STEP 2: Ask MarketDetector for the current state (read-only, no trading)
    currentMarketState = MarketDetector(currentObservation, previousObservation, hasPreviousObservation);

    // STEP 3: Run AutoCut monitor
    AutoCut();

    // STEP 4: Activate exactly ONE Mind - all others remain disabled
    switch(currentMarketState)
    {
        case STATE_STRONG_UPTREND:
            Logger(LOG_MIND, "Mind1 active (Strong Uptrend)");
            Mind1();
            break;

        case STATE_NEUTRAL_CHOPPY:
            Logger(LOG_MIND, "Mind2 active (Neutral/Choppy)");
            Mind2();
            break;

        case STATE_STRONG_DOWNTREND:
            Logger(LOG_MIND, "Mind3 active (Strong Downtrend)");
            Mind3();
            break;

        case STATE_HIGH_VOLATILITY:
            Logger(LOG_MIND, "Mind4 active (High Volatility)");
            Mind4();
            break;
    }

    // STEP 5: Periodic status log
    if(LogIntervalSec > 0 && currentTime % LogIntervalSec == 0)
        Logger(LOG_INFO, "Status | State: " + EnumToString(currentMarketState) +
               " | Open: "     + IntegerToString(TradeManager_CountOpen()) +
               " | Hist: "     + IntegerToString(historyCount) +
               " | AvgSpd: "   + DoubleToString(historyAvgSpeed, 5));
}

//+------------------------------------------------------------------+
// END OF EXPERT ADVISOR
//+------------------------------------------------------------------+
