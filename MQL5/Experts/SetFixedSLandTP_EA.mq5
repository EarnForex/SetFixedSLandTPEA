#property link          "https://www.earnforex.com/metatrader-expert-advisors/SetFixedSLandTPEA/"
#property version       "1.00"

#property copyright     "EarnForex.com - 2025"
#property description   "This EA constantly monitors your positions and pending orders and sets a stop-loss and, if required a take-profit, to all trades based on the given filters."
#property description   ""
#property description   "DISCLAIMER: This EA comes with no guarantee. Use it at your own risk."
#property description   "It is best to test it on a demo account first."
#property description   ""
#property description   "Find more on EarnForex.com"
#property icon          "\\Files\\EF-Icon-64x64px.ico"

#include <Trade/Trade.mqh>
#include <MQLTA ErrorHandling.mqh>
#include <MQLTA Utils.mqh>

enum ENUM_PRICE_TYPE
{
    PRICE_TYPE_OPEN,   // Trade's open price
    PRICE_TYPE_CURRENT // Current price
};

enum ENUM_ORDER_TYPES
{
    ALL_ORDERS = 1, // ALL TRADES
    ONLY_BUY = 2,   // BUY ONLY
    ONLY_SELL = 3   // SELL ONLY
};

enum ENUM_TP_TYPE
{
    TP_TYPE_POINTS,     // Points
    TP_TYPE_LEVEL,      // Level
    TP_TYPE_PERCENTAGE, // Percentage of SL
    TP_TYPE_UNCHANGED   // Keep TP unchanged
};

enum ENUM_SL_TYPE
{
    SL_TYPE_POINTS,     // Points
    SL_TYPE_LEVEL,      // Level
    SL_TYPE_UNCHANGED   // Keep SL unchanged
};

// Input parameters.
input group "SL & TP"
input double StopLoss = 200;          // Stop-loss
input ENUM_SL_TYPE StopLossType = SL_TYPE_POINTS; // Stop-loss type
input bool OverwriteExistingSL = false; // Overwrite existing SL?
input double TakeProfit = 400;        // Take-profit
input ENUM_TP_TYPE TakeProfitType = TP_TYPE_POINTS; // Take-profit type
input bool OverwriteExistingTP = false; // Overwrite existing TP?

input group "Filters"
input bool CurrentSymbolOnly = true;  // Current symbol only?
input ENUM_ORDER_TYPES OrderTypeFilter = ALL_ORDERS; // Type of trades to apply to
input bool OnlyMagicNumber = false;   // Modify only orders matching the magic number
input int MagicNumber = 0;            // Matching magic number
input bool OnlyWithComment = false;   // Modify only trades with the following comment
input string MatchingComment = "";    // Matching comment
input bool ApplyToPending = false;    // Apply to pending orders too?

input group "Execution"
input ENUM_PRICE_TYPE PriceType = PRICE_TYPE_OPEN; // Price to use for SL/TP setting
input bool ProcessOnceOnly = true;    // Process each position/order only once?
input int CheckIntervalSeconds = 1;   // Check interval in seconds
input bool InputEnableExpert = false; // Enable EA

input group "Control panel"
input bool ShowPanel = true;         // Show graphical panel
input string ExpertName = "SLTP";    // Expert name (to name the objects)
input int Xoff = 20;                 // Horizontal spacing for the control panel
input int Yoff = 20;                 // Vertical spacing for the control panel
input ENUM_BASE_CORNER ChartCorner = CORNER_LEFT_UPPER; // Chart corner
input int FontSize = 10;             // Font size

// Global variables.
CTrade *Trade;
bool EnableExpert;          // Main enable/disable flag.
ulong ProcessedPositions[]; // Array to store processed position tickets.
ulong ProcessedOrders[];    // Array to store processed order tickets.
datetime LastCheckTime;     // For processed positions/orders cleanup.

// Panel variables.
double DPIScale; // Scaling parameter for the panel based on the screen DPI.
int PanelMovY, PanelLabX, PanelLabY, PanelRecX;
string PanelBase = "";
string PanelLabel = "";
string PanelEnableDisable = "";

int OnInit()
{
    EnableExpert = InputEnableExpert;

    // Create trade object.
    Trade = new CTrade;

    // Initialize arrays.
    ArrayResize(ProcessedPositions, 0);
    ArrayResize(ProcessedOrders, 0);
    LastCheckTime = 0;

    // Initialize panel variables.
    PanelBase = ExpertName + "-P-BAS";
    PanelLabel = ExpertName + "-P-LAB";
    PanelEnableDisable = ExpertName + "-P-ENADIS";

    CleanPanel();

    DPIScale = (double)TerminalInfoInteger(TERMINAL_SCREEN_DPI) / 96.0;
    PanelMovY = (int)MathRound(20 * DPIScale);
    PanelLabX = (int)MathRound(150 * DPIScale);
    PanelLabY = PanelMovY;
    PanelRecX = PanelLabX + 4;

    if (ShowPanel) DrawPanel();

    EventSetTimer(CheckIntervalSeconds);

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    CleanPanel();

    delete Trade;
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
    if (id == CHARTEVENT_OBJECT_CLICK)
    {
        if (sparam == PanelEnableDisable)
        {
            ChangeTrailingEnabled();
        }
    }
    else if (id == CHARTEVENT_KEYDOWN)
    {
        if (lparam == 27) // ESC key.
        {
            if (MessageBox("Are you sure you want to close the EA?", "EXIT ?", MB_YESNO) == IDYES)
            {
                ExpertRemove();
            }
        }
    }
}

void OnTimer()
{
    // Update panel if enabled.
    if (ShowPanel) DrawPanel();

    // Only process if enabled.
    if (!EnableExpert) return;

    // Check connection and trading status.
    if (!TerminalInfoInteger(TERMINAL_CONNECTED))
    {
        return;
    }

    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        return;
    }

    if (!MQLInfoInteger(MQL_TRADE_ALLOWED))
    {
        return;
    }

    // Process positions.
    ProcessPositions();

    // Clean up closed positions from the array periodically.
    if (ProcessOnceOnly && ArraySize(ProcessedPositions) > 0) CleanupProcessedPositions();

    // Process pending orders if enabled.
    if (ApplyToPending)
    {
        ProcessPendingOrders();
        // Clean up deleted orders from the array periodically.
        if (ProcessOnceOnly && ArraySize(ProcessedOrders) > 0) CleanupProcessedOrders();
    }
}

void ProcessPositions()
{
    int positions_total = PositionsTotal();

    for (int i = positions_total - 1; i >= 0; i--) // Going backwards in case positions are closed.
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket <= 0) continue;

        // Check if already processed.
        if (ProcessOnceOnly && IsPositionProcessed(ticket)) continue;

        // Check filters.
        if (!PassesPositionFilters(ticket)) continue;

        // Process the position.
        if (ModifyPosition(ticket))
        {
            // Mark as processed if successful.
            if (ProcessOnceOnly)
            {
                AddProcessedPosition(ticket);
            }
        }
    }
}

void ProcessPendingOrders()
{
    int orders_total = OrdersTotal();

    for (int i = orders_total - 1; i >= 0; i--) // Going backwards in case orders are deleted.
    {
        ulong ticket = OrderGetTicket(i);
        if (ticket <= 0) continue;

        // Check if already processed.
        if (ProcessOnceOnly && IsOrderProcessed(ticket)) continue;

        // Check filters.
        if (!PassesOrderFilters(ticket)) continue;

        // Process the order.
        if (ModifyOrder(ticket))
        {
            // Mark as processed if successful.
            if (ProcessOnceOnly)
            {
                AddProcessedOrder(ticket);
            }
        }
    }
}

bool PassesPositionFilters(ulong ticket)
{
    if (!PositionSelectByTicket(ticket)) return false;

    // Check order type filter.
    if ((OrderTypeFilter == ONLY_SELL) && (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)) return false;
    if ((OrderTypeFilter == ONLY_BUY) && (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)) return false;

    // Check symbol filter.
    if (CurrentSymbolOnly && (PositionGetString(POSITION_SYMBOL) != Symbol())) return false;

    // Check magic number filter.
    if (OnlyMagicNumber && (PositionGetInteger(POSITION_MAGIC) != MagicNumber)) return false;

    // Check comment filter.
    if (OnlyWithComment && (StringCompare(PositionGetString(POSITION_COMMENT), MatchingComment) != 0)) return false;

    return true;
}

bool PassesOrderFilters(ulong ticket)
{
    if (!OrderSelect(ticket)) return false;

    // Check order type filter.
    ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

    if (OrderTypeFilter == ONLY_SELL)
    {
        if (order_type != ORDER_TYPE_SELL_STOP &&
            order_type != ORDER_TYPE_SELL_LIMIT &&
            order_type != ORDER_TYPE_SELL_STOP_LIMIT) return false;
    }

    if (OrderTypeFilter == ONLY_BUY)
    {
        if (order_type != ORDER_TYPE_BUY_STOP &&
            order_type != ORDER_TYPE_BUY_LIMIT &&
            order_type != ORDER_TYPE_BUY_STOP_LIMIT) return false;
    }

    // Check symbol filter.
    if (CurrentSymbolOnly && (OrderGetString(ORDER_SYMBOL) != Symbol())) return false;

    // Check magic number filter.
    if (OnlyMagicNumber && (OrderGetInteger(ORDER_MAGIC) != MagicNumber)) return false;

    // Check comment filter.
    if (OnlyWithComment && (StringCompare(OrderGetString(ORDER_COMMENT), MatchingComment) != 0)) return false;

    return true;
}

bool ModifyPosition(ulong ticket)
{
    if (!PositionSelectByTicket(ticket)) return false;

    string symbol = PositionGetString(POSITION_SYMBOL);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

    // Check if trading is enabled for symbol.
    if (SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
    {
        return false;
    }

    double Price;
    double TakeProfitPrice = 0;
    double StopLossPrice = 0;
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

    if (tick_size == 0) return false;

    // Calculate SL/TP based on position type.
    if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
    {
        CalculateBuySLTP(symbol, Price, StopLossPrice, TakeProfitPrice, digits, tick_size, point, true);
    }
    else if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
    {
        CalculateSellSLTP(symbol, Price, StopLossPrice, TakeProfitPrice, digits, tick_size, point, true);
    }

    // Avoid modifying existing SL/TP if overwriting isn't allowed.
    if (!OverwriteExistingSL && PositionGetDouble(POSITION_SL) > 0) StopLossPrice = PositionGetDouble(POSITION_SL);
    if (!OverwriteExistingTP && PositionGetDouble(POSITION_TP) > 0) TakeProfitPrice = PositionGetDouble(POSITION_TP);

    // Check if modification is needed.
    if ((MathAbs(StopLossPrice - PositionGetDouble(POSITION_SL)) < point / 2) &&
        (MathAbs(TakeProfitPrice - PositionGetDouble(POSITION_TP)) < point / 2))
    {
        return false; // No modification needed.
    }

    if (Trade.PositionModify(ticket, StopLossPrice, TakeProfitPrice))
    {
        Print("Position #", ticket, " modified: SL=", StopLossPrice, " TP=", TakeProfitPrice);
        return true;
    }
    else
    {
        Print("Failed to modify position #", ticket, ": Error ", GetLastError());
        return false;
    }
}

bool ModifyOrder(ulong ticket)
{
    if (!OrderSelect(ticket)) return false;

    string symbol = OrderGetString(ORDER_SYMBOL);
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

    // Check if trading is enabled for symbol.
    if (SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
    {
        return false;
    }

    double Price;
    double TakeProfitPrice = 0;
    double StopLossPrice = 0;
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

    if (tick_size == 0) return false;

    ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

    // Calculate SL/TP based on order type.
    if (order_type == ORDER_TYPE_BUY_STOP || order_type == ORDER_TYPE_BUY_LIMIT || order_type == ORDER_TYPE_BUY_STOP_LIMIT)
    {
        CalculateBuySLTP(symbol, Price, StopLossPrice, TakeProfitPrice, digits, tick_size, point, false);
    }
    else if (order_type == ORDER_TYPE_SELL_STOP || order_type == ORDER_TYPE_SELL_LIMIT || order_type == ORDER_TYPE_SELL_STOP_LIMIT)
    {
        CalculateSellSLTP(symbol, Price, StopLossPrice, TakeProfitPrice, digits, tick_size, point, false);
    }

    // Avoid modifying existing SL/TP if overwriting isn't allowed.
    if (!OverwriteExistingSL && OrderGetDouble(ORDER_SL) > 0) StopLossPrice = OrderGetDouble(ORDER_SL);
    if (!OverwriteExistingTP && OrderGetDouble(ORDER_TP) > 0) TakeProfitPrice = OrderGetDouble(ORDER_TP);

    // Check if modification is needed.
    if ((MathAbs(StopLossPrice - OrderGetDouble(ORDER_SL)) < point / 2) &&
        (MathAbs(TakeProfitPrice - OrderGetDouble(ORDER_TP)) < point / 2))
    {
        return false; // No modification needed.
    }

    if (Trade.OrderModify(ticket, OrderGetDouble(ORDER_PRICE_OPEN), StopLossPrice, TakeProfitPrice,
                         (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME), OrderGetInteger(ORDER_TIME_EXPIRATION)))
    {
        Print("Order #", ticket, " modified: SL=", StopLossPrice, " TP=", TakeProfitPrice);
        return true;
    }
    else
    {
        Print("Failed to modify order #", ticket, ": Error ", GetLastError());
        return false;
    }
}

void CalculateBuySLTP(string symbol, double &Price, double &StopLossPrice, double &TakeProfitPrice,
                      int digits, double tick_size, double point, bool isPosition)
{
    if (PriceType == PRICE_TYPE_CURRENT)
    {
        Price = SymbolInfoDouble(symbol, SYMBOL_BID);
    }
    else
    {
        if (isPosition)
            Price = PositionGetDouble(POSITION_PRICE_OPEN);
        else
            Price = OrderGetDouble(ORDER_PRICE_OPEN);
    }

    // Calculate Stop-loss.
    if (StopLossType == SL_TYPE_UNCHANGED)
    {
        StopLossPrice = isPosition ? PositionGetDouble(POSITION_SL) : OrderGetDouble(ORDER_SL);
    }
    else if (StopLossType == SL_TYPE_LEVEL)
    {
        StopLossPrice = StopLoss;
    }
    else if (StopLossType == SL_TYPE_POINTS)
    {
        if (StopLoss > 0)
        {
            StopLossPrice = NormalizeDouble(Price - StopLoss * point, digits);
            StopLossPrice = NormalizeDouble(MathRound(StopLossPrice / tick_size) * tick_size, digits);
        }
    }

    // Calculate Take-profit.
    if (TakeProfitType == TP_TYPE_UNCHANGED)
    {
        TakeProfitPrice = isPosition ? PositionGetDouble(POSITION_TP) : OrderGetDouble(ORDER_TP);
    }
    else if (TakeProfitType == TP_TYPE_LEVEL)
    {
        TakeProfitPrice = TakeProfit;
    }
    else if (TakeProfitType == TP_TYPE_POINTS)
    {
        if (TakeProfit > 0)
        {
            TakeProfitPrice = NormalizeDouble(Price + TakeProfit * point, digits);
            TakeProfitPrice = NormalizeDouble(MathRound(TakeProfitPrice / tick_size) * tick_size, digits);
        }
    }
    else if (TakeProfitType == TP_TYPE_PERCENTAGE)
    {
        double sl_distance = 0;
        double open_price = isPosition ? PositionGetDouble(POSITION_PRICE_OPEN) : OrderGetDouble(ORDER_PRICE_OPEN);
        double current_sl = isPosition ? PositionGetDouble(POSITION_SL) : OrderGetDouble(ORDER_SL);

        if (StopLossPrice > 0)
            sl_distance = open_price - StopLossPrice;
        else if (current_sl > 0)
            sl_distance = open_price - current_sl;

        if (sl_distance > 0)
        {
            TakeProfitPrice = NormalizeDouble(Price + sl_distance * TakeProfit / 100, digits);
            TakeProfitPrice = NormalizeDouble(MathRound(TakeProfitPrice / tick_size) * tick_size, digits);
        }
    }
}

void CalculateSellSLTP(string symbol, double &Price, double &StopLossPrice, double &TakeProfitPrice,
                       int digits, double tick_size, double point, bool isPosition)
{
    if (PriceType == PRICE_TYPE_CURRENT)
    {
        Price = SymbolInfoDouble(symbol, SYMBOL_ASK);
    }
    else
    {
        if (isPosition)
            Price = PositionGetDouble(POSITION_PRICE_OPEN);
        else
            Price = OrderGetDouble(ORDER_PRICE_OPEN);
    }

    // Calculate Stop-loss.
    if (StopLossType == SL_TYPE_UNCHANGED)
    {
        StopLossPrice = isPosition ? PositionGetDouble(POSITION_SL) : OrderGetDouble(ORDER_SL);
    }
    else if (StopLossType == SL_TYPE_LEVEL)
    {
        StopLossPrice = StopLoss;
    }
    else if (StopLossType == SL_TYPE_POINTS)
    {
        if (StopLoss > 0)
        {
            StopLossPrice = NormalizeDouble(Price + StopLoss * point, digits);
            StopLossPrice = NormalizeDouble(MathRound(StopLossPrice / tick_size) * tick_size, digits);
        }
    }

    // Calculate Take-profit.
    if (TakeProfitType == TP_TYPE_UNCHANGED)
    {
        TakeProfitPrice = isPosition ? PositionGetDouble(POSITION_TP) : OrderGetDouble(ORDER_TP);
    }
    else if (TakeProfitType == TP_TYPE_LEVEL)
    {
        TakeProfitPrice = TakeProfit;
    }
    else if (TakeProfitType == TP_TYPE_POINTS)
    {
        if (TakeProfit > 0)
        {
            TakeProfitPrice = NormalizeDouble(Price - TakeProfit * point, digits);
            TakeProfitPrice = NormalizeDouble(MathRound(TakeProfitPrice / tick_size) * tick_size, digits);
        }
    }
    else if (TakeProfitType == TP_TYPE_PERCENTAGE)
    {
        double sl_distance = 0;
        double open_price = isPosition ? PositionGetDouble(POSITION_PRICE_OPEN) : OrderGetDouble(ORDER_PRICE_OPEN);
        double current_sl = isPosition ? PositionGetDouble(POSITION_SL) : OrderGetDouble(ORDER_SL);

        if (StopLossPrice > 0)
            sl_distance = StopLossPrice - open_price;
        else if (current_sl > 0)
            sl_distance = current_sl - open_price;

        if (sl_distance > 0)
        {
            TakeProfitPrice = NormalizeDouble(Price - sl_distance * TakeProfit / 100, digits);
            TakeProfitPrice = NormalizeDouble(MathRound(TakeProfitPrice / tick_size) * tick_size, digits);
        }
    }
}

bool IsPositionProcessed(ulong ticket)
{
    int size = ArraySize(ProcessedPositions);

    for (int i = 0; i < size; i++)
    {
        if (ProcessedPositions[i] == ticket) return true;
    }

    return false;
}

bool IsOrderProcessed(ulong ticket)
{
    int size = ArraySize(ProcessedOrders);

    for (int i = 0; i < size; i++)
    {
        if (ProcessedOrders[i] == ticket) return true;
    }

    return false;
}

void AddProcessedPosition(ulong ticket)
{
    int size = ArraySize(ProcessedPositions);
    ArrayResize(ProcessedPositions, size + 1, 10);
    ProcessedPositions[size] = ticket;
}

void AddProcessedOrder(ulong ticket)
{
    int size = ArraySize(ProcessedOrders);
    ArrayResize(ProcessedOrders, size + 1, 10);
    ProcessedOrders[size] = ticket;
}

void CleanupProcessedPositions()
{
    if (TimeCurrent() - LastCheckTime < CheckIntervalSeconds * 10) return; // Check only once every 10 x CheckIntervalSeconds.
    int size = ArraySize(ProcessedPositions);
    for (int i = 0; i < size; i++)
    {
        ulong ticket = ProcessedPositions[i];
        if (!PositionSelectByTicket(ticket))
        {
            size--; // One element less.
            for (int j = i; j < size; j++) // Shift all array elements left to remove the current one (i).
                ProcessedPositions[j] = ProcessedPositions[j + 1];
            ArrayResize(ProcessedPositions, size); // New size.
        }
    }
    LastCheckTime = TimeCurrent();
    
}

void CleanupProcessedOrders()
{
    if (TimeCurrent() - LastCheckTime < CheckIntervalSeconds * 10) return; // Check only once every 10 x CheckIntervalSeconds.
    int size = ArraySize(ProcessedOrders);
    for (int i = 0; i < size; i++)
    {
        ulong ticket = ProcessedOrders[i];
        if (!OrderSelect(ticket))
        {
            size--; // One element less.
            for (int j = i; j < size; j++) // Shift all array elements left to remove the current one (i).
                ProcessedOrders[j] = ProcessedOrders[j + 1];
            ArrayResize(ProcessedOrders, size); // New size.
        }
    }
    LastCheckTime = TimeCurrent();
}

void DrawPanel()
{
    int SignX = 1;
    int YAdjustment = 0;
    if ((ChartCorner == CORNER_RIGHT_UPPER) || (ChartCorner == CORNER_RIGHT_LOWER))
    {
        SignX = -1; // Correction for right-side panel position.
    }
    if ((ChartCorner == CORNER_RIGHT_LOWER) || (ChartCorner == CORNER_LEFT_LOWER))
    {
        YAdjustment = (PanelMovY + 2) * 2 + 1 - PanelLabY; // Correction for lower side panel position.
    }

    string PanelText = "FIXED SL/TP";
    string PanelToolTip = "Set fixed stop-loss and take-profit";
    int Rows = 1;

    // Create base rectangle.
    ObjectCreate(ChartID(), PanelBase, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_CORNER, ChartCorner);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_XDISTANCE, Xoff);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_YDISTANCE, Yoff + YAdjustment);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_XSIZE, PanelRecX);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_YSIZE, (PanelMovY + 1) * (Rows + 1) + 3);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_BGCOLOR, clrWhite);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_HIDDEN, true);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(ChartID(), PanelBase, OBJPROP_COLOR, clrBlack);

    // Create main label.
    DrawEdit(PanelLabel,
             Xoff + 2 * SignX,
             Yoff + 2,
             PanelLabX,
             PanelLabY,
             true,
             FontSize,
             PanelToolTip,
             ALIGN_CENTER,
             "Consolas",
             PanelText,
             false,
             clrNavy,
             clrKhaki,
             clrBlack);
    ObjectSetInteger(ChartID(), PanelLabel, OBJPROP_CORNER, ChartCorner);

    // Create enable/disable button.
    string EnableDisabledText = "";
    color EnableDisabledColor = clrNavy;
    color EnableDisabledBack = clrKhaki;

    if (EnableExpert)
    {
        EnableDisabledText = "EXPERT ENABLED";
        EnableDisabledColor = clrWhite;
        EnableDisabledBack = clrDarkGreen;
    }
    else
    {
        EnableDisabledText = "EXPERT DISABLED";
        EnableDisabledColor = clrWhite;
        EnableDisabledBack = clrDarkRed;
    }

    if (ObjectFind(ChartID(), PanelEnableDisable) >= 0)
    {
        ObjectSetString(ChartID(), PanelEnableDisable, OBJPROP_TEXT, EnableDisabledText);
        ObjectSetInteger(ChartID(), PanelEnableDisable, OBJPROP_COLOR, EnableDisabledColor);
        ObjectSetInteger(ChartID(), PanelEnableDisable, OBJPROP_BGCOLOR, EnableDisabledBack);
    }
    else
    {
        DrawEdit(PanelEnableDisable,
                 Xoff + 2 * SignX,
                 Yoff + (PanelMovY + 1) * Rows + 2,
                 PanelLabX,
                 PanelLabY,
                 true,
                 FontSize,
                 "Click to enable or disable the SL/TP modification feature.",
                 ALIGN_CENTER,
                 "Consolas",
                 EnableDisabledText,
                 false,
                 EnableDisabledColor,
                 EnableDisabledBack,
                 clrBlack);
    }
    ObjectSetInteger(ChartID(), PanelEnableDisable, OBJPROP_CORNER, ChartCorner);
    ChartRedraw();
}

void CleanPanel()
{
    ObjectsDeleteAll(ChartID(), ExpertName + "-P-");
    ChartRedraw();
}

void ChangeTrailingEnabled()
{
    if (EnableExpert == false)
    {
        if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        {
            MessageBox("Algorithmic trading is disabled in the platform's options! Please enable it via Tools->Options->Expert Advisors.", "WARNING", MB_OK);
            return;
        }
        if (!MQLInfoInteger(MQL_TRADE_ALLOWED))
        {
            MessageBox("Algo Trading is disabled in the EA's settings! Please tick the Allow Algo Trading checkbox on the Common tab.", "WARNING", MB_OK);
            return;
        }
        EnableExpert = true;
        Print("SetFixedSLTP EA enabled.");
    }
    else
    {
        EnableExpert = false;
        Print("SetFixedSLTP EA disabled.");
    }
    DrawPanel();
}
//+------------------------------------------------------------------+