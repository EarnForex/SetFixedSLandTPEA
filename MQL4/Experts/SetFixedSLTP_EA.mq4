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
input string Group_1 = "===================="; // SL & TP
input double StopLoss = 200;          // Stop-loss
input ENUM_SL_TYPE StopLossType = SL_TYPE_POINTS; // Stop-loss type
input bool OverwriteExistingSL = false; // Overwrite existing SL?
input double TakeProfit = 400;        // Take-profit
input ENUM_TP_TYPE TakeProfitType = TP_TYPE_POINTS; // Take-profit type
input bool OverwriteExistingTP = false; // Overwrite existing TP?

input string Group_2 = "===================="; // Filters
input bool CurrentSymbolOnly = true;  // Current symbol only?
input ENUM_ORDER_TYPES OrderTypeFilter = ALL_ORDERS; // Type of trades to apply to
input bool OnlyMagicNumber = false;   // Modify only trades matching the magic number
input int MagicNumber = 0;            // Matching magic number
input bool OnlyWithComment = false;   // Modify only trades with the following comment
input string MatchingComment = "";    // Matching comment
input bool ApplyToPending = false;    // Apply to pending orders too?

input string Group_3 = "===================="; // Execution
input ENUM_PRICE_TYPE PriceType = PRICE_TYPE_OPEN; // Price to use for SL/TP setting
input bool ProcessOnceOnly = true;    // Process each position/order only once?
input int CheckIntervalSeconds = 1;   // Check interval in seconds
input bool InputEnableExpert = false; // Enable EA

input string Group_4 = "===================="; // Control panel
input bool ShowPanel = true;          // Show graphical panel
input string ExpertName = "SLTP";     // Expert name (to name the objects)
input int Xoff = 20;                  // Horizontal spacing for the control panel
input int Yoff = 20;                  // Vertical spacing for the control panel
input ENUM_BASE_CORNER ChartCorner = CORNER_LEFT_UPPER; // Chart corner
input int FontSize = 10;              // Font size

// Global variables.
bool EnableExpert;      // Main enable/disable flag.
int ProcessedOrders[];  // Array to store processed order tickets.
datetime LastCheckTime; // For processed orders cleanup.

// Panel variables.
double DPIScale; // Scaling parameter for the panel based on the screen DPI.
int PanelMovY, PanelLabX, PanelLabY, PanelRecX;
string PanelBase = "";
string PanelLabel = "";
string PanelEnableDisable = "";

int OnInit()
{
    EnableExpert = InputEnableExpert;

    // Initialize arrays.
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
    // Clean up panel.
    CleanPanel();
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

    // Process all orders (both positions and pending).
    ProcessOrders();

    // Clean up closed orders from the array periodically.
    if (ProcessOnceOnly && ArraySize(ProcessedOrders) > 0) CleanupProcessedOrders();
}

void ProcessOrders()
{
    // Scan the orders backwards.
    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        // Select the order. If not selected print the error and continue with the next index.
        if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) == false)
        {
            Print("ERROR - Unable to select the order - ", GetLastError());
            continue;
        }

        int ticket = OrderTicket();
        
        // Check if already processed.
        if (ProcessOnceOnly && IsOrderProcessed(ticket)) continue;

        // Check if the order matches the filters.
        if (!PassesOrderFilters()) continue;

        // Process the order.
        if (ModifyOrder())
        {
            // Mark as processed if successful.
            if (ProcessOnceOnly)
            {
                AddProcessedOrder(ticket);
            }
        }
    }
}

bool PassesOrderFilters()
{
    // Check if pending order and if we should process pending.
    if (!ApplyToPending && (OrderType() != OP_BUY) && (OrderType() != OP_SELL)) return false;
    
    // Check symbol filter.
    if (CurrentSymbolOnly && (OrderSymbol() != Symbol())) return false;
    
    // Check magic number filter.
    if (OnlyMagicNumber && (OrderMagicNumber() != MagicNumber)) return false;
    
    // Check comment filter.
    if (OnlyWithComment && (StringCompare(OrderComment(), MatchingComment) != 0)) return false;
    
    // Check order type filter.
    if (OrderTypeFilter == ONLY_SELL)
    {
        if ((OrderType() == OP_BUY) || (OrderType() == OP_BUYLIMIT) || (OrderType() == OP_BUYSTOP)) return false;
    }
    if (OrderTypeFilter == ONLY_BUY)
    {
        if ((OrderType() == OP_SELL) || (OrderType() == OP_SELLLIMIT) || (OrderType() == OP_SELLSTOP)) return false;
    }
    
    return true;
}

bool ModifyOrder()
{
    string symbol = OrderSymbol();
    double TakeProfitPrice = 0;
    double StopLossPrice = 0;
    double Price;
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    
    // Check if trading is enabled for symbol.
    if (SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
    {
        return false;
    }

    double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    if (tick_size == 0)
    {
        return false;
    }

    // Calculate SL/TP based on order type.
    if ((OrderType() == OP_BUY) || (OrderType() == OP_BUYLIMIT) || (OrderType() == OP_BUYSTOP))
    {
        CalculateBuySLTP(symbol, Price, StopLossPrice, TakeProfitPrice, digits, tick_size, point);
    }
    else if ((OrderType() == OP_SELL) || (OrderType() == OP_SELLLIMIT) || (OrderType() == OP_SELLSTOP))
    {
        CalculateSellSLTP(symbol, Price, StopLossPrice, TakeProfitPrice, digits, tick_size, point);
    }

    // Avoid modifying existing SL/TP if overwriting isn't allowed.
    if (!OverwriteExistingSL && OrderStopLoss() > 0) StopLossPrice = OrderStopLoss();
    if (!OverwriteExistingTP && OrderTakeProfit() > 0) TakeProfitPrice = OrderTakeProfit();

    // Check if modification is needed.
    if ((MathAbs(StopLossPrice - OrderStopLoss()) < point / 2) && 
        (MathAbs(TakeProfitPrice - OrderTakeProfit()) < point / 2))
    {
        return false; // No modification needed.
    }

    if (OrderModify(OrderTicket(), OrderOpenPrice(), StopLossPrice, TakeProfitPrice, OrderExpiration()))
    {
        Print("Order #", OrderTicket(), " on ", OrderSymbol(), " modified: SL=", StopLossPrice, " TP=", TakeProfitPrice);
        return true;
    }
    else
    {
        Print("Order #", OrderTicket(), " on ", OrderSymbol(), " failed to update SL to ", StopLossPrice, " and TP to ", TakeProfitPrice, " with error - ", GetLastError());
        return false;
    }
}

void CalculateBuySLTP(string symbol, double &Price, double &StopLossPrice, double &TakeProfitPrice,
                      int digits, double tick_size, double point)
{
    if (PriceType == PRICE_TYPE_CURRENT)
    {
        RefreshRates();
        // Should be Bid for Buy orders.
        Price = SymbolInfoDouble(symbol, SYMBOL_BID);
    }
    else 
    {
        Price = OrderOpenPrice();
    }
    
    // Calculate Stop-loss.
    if (StopLossType == SL_TYPE_UNCHANGED)
    {
        StopLossPrice = OrderStopLoss();
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
            StopLossPrice = NormalizeDouble(MathRound(StopLossPrice / tick_size) * tick_size, digits); // Adjusting for tick size granularity.
        }
    }
    
    // Calculate Take-profit.
    if (TakeProfitType == TP_TYPE_UNCHANGED)
    {
        TakeProfitPrice = OrderTakeProfit();
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
            TakeProfitPrice = NormalizeDouble(MathRound(TakeProfitPrice / tick_size) * tick_size, digits); // Adjusting for tick size granularity.
        }
    }
    else if (TakeProfitType == TP_TYPE_PERCENTAGE)
    {
        double sl_distance = 0;
        if (StopLossPrice > 0) 
            sl_distance = OrderOpenPrice() - StopLossPrice;
        else if (OrderStopLoss() > 0) 
            sl_distance = OrderOpenPrice() - OrderStopLoss();
            
        if (sl_distance > 0)
        {
            TakeProfitPrice = NormalizeDouble(Price + sl_distance * TakeProfit / 100, digits);
            TakeProfitPrice = NormalizeDouble(MathRound(TakeProfitPrice / tick_size) * tick_size, digits); // Adjusting for tick size granularity.
        }
    }
}

void CalculateSellSLTP(string symbol, double &Price, double &StopLossPrice, double &TakeProfitPrice,
                       int digits, double tick_size, double point)
{
    if (PriceType == PRICE_TYPE_CURRENT)
    {
        RefreshRates();
        // Should be Ask for Sell orders.
        Price = SymbolInfoDouble(symbol, SYMBOL_ASK);
    }
    else 
    {
        Price = OrderOpenPrice();
    }
    
    // Calculate Stop-loss.
    if (StopLossType == SL_TYPE_UNCHANGED)
    {
        StopLossPrice = OrderStopLoss();
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
            StopLossPrice = NormalizeDouble(MathRound(StopLossPrice / tick_size) * tick_size, digits); // Adjusting for tick size granularity.
        }
    }
    
    // Calculate Take-profit.
    if (TakeProfitType == TP_TYPE_UNCHANGED)
    {
        TakeProfitPrice = OrderTakeProfit();
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
            TakeProfitPrice = NormalizeDouble(MathRound(TakeProfitPrice / tick_size) * tick_size, digits); // Adjusting for tick size granularity.
        }
    }
    else if (TakeProfitType == TP_TYPE_PERCENTAGE)
    {
        double sl_distance = 0;
        if (StopLossPrice > 0) 
            sl_distance = StopLossPrice - OrderOpenPrice();
        else if (OrderStopLoss() > 0) 
            sl_distance = OrderStopLoss() - OrderOpenPrice();
            
        if (sl_distance > 0)
        {
            TakeProfitPrice = NormalizeDouble(Price - sl_distance * TakeProfit / 100, digits);
            TakeProfitPrice = NormalizeDouble(MathRound(TakeProfitPrice / tick_size) * tick_size, digits); // Adjusting for tick size granularity.
        }
    }
}

bool IsOrderProcessed(int ticket)
{
    int size = ArraySize(ProcessedOrders);
    
    for (int i = 0; i < size; i++)
    {
        if (ProcessedOrders[i] == ticket) return true;
    }
    
    return false;
}

void AddProcessedOrder(int ticket)
{
    int size = ArraySize(ProcessedOrders);
    ArrayResize(ProcessedOrders, size + 1, 10);
    ProcessedOrders[size] = ticket;
}

void CleanupProcessedOrders()
{
    if (TimeCurrent() - LastCheckTime < CheckIntervalSeconds * 10) return; // Check only once every 10 x CheckIntervalSeconds.
    int size = ArraySize(ProcessedOrders);
    for (int i = 0; i < size; i++)
    {
        int ticket = ProcessedOrders[i];
        if (!OrderSelect(ticket, SELECT_BY_TICKET))
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
}

void CleanPanel()
{
    ObjectsDeleteAll(ChartID(), ExpertName + "-P-");
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