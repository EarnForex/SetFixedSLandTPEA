// -------------------------------------------------------------------------------
//   This EA constantly monitors your positions and pending orders and sets a stop-loss and, if required a take-profit, to all trades based on the given filters.
//   DISCLAIMER: This EA comes with no guarantee. Use it at your own risk.
//   It is best to test it on a demo account first.
//
//   Version 1.00
//   Copyright 2025, EarnForex.com
//   https://www.earnforex.com/metatrader-expert-advisors/SetFixedSLandTPEA/
// -------------------------------------------------------------------------------

using System;
using System.Collections.Generic;
using System.Linq;
using cAlgo.API;
using cAlgo.API.Internals;

namespace cAlgo.Robots
{
    [Robot(AccessRights = AccessRights.None)]
    public class SetFixedSLTPRobot : Robot
    {
        // Enumerations.
        public enum PriceType
        {
            Open,   // Trade's open price.
            Current // Current price.
        }

        public enum OrderTypes
        {
            All = 1,  // ALL TRADES.
            Buy = 2,  // BUY ONLY.
            Sell = 3  // SELL ONLY.
        }

        public enum TPType
        {
            Points,     // Points.
            Level,      // Level.
            Percentage, // Percentage of SL.
            Unchanged   // Keep TP unchanged.
        }

        public enum SLType
        {
            Points,     // Points.
            Level,      // Level.
            Unchanged   // Keep SL unchanged.
        }

        // Input parameters.
        [Parameter("Stop-loss", DefaultValue = 200, Group = "SL & TP")]
        public double StopLoss { get; set; }

        [Parameter("Stop-loss type", DefaultValue = SLType.Points, Group = "SL & TP")]
        public SLType StopLossType { get; set; }

        [Parameter("Overwrite existing SL?", DefaultValue = false, Group = "SL & TP")]
        public bool OverwriteExistingSL { get; set; }

        [Parameter("Take-profit", DefaultValue = 400, Group = "SL & TP")]
        public double TakeProfit { get; set; }

        [Parameter("Take-profit type", DefaultValue = TPType.Points, Group = "TradSL & TPing")]
        public TPType TakeProfitType { get; set; }

        [Parameter("Overwrite existing TP?", DefaultValue = false, Group = "SL & TP")]
        public bool OverwriteExistingTP { get; set; }

        [Parameter("Current symbol only?", DefaultValue = true, Group = "Filters")]
        public bool CurrentSymbolOnly { get; set; }

        [Parameter("Type of trades to apply to", DefaultValue = OrderTypes.All, Group = "Filters")]
        public OrderTypes OrderTypeFilter { get; set; }

        [Parameter("Modify only orders matching the magic number", DefaultValue = false, Group = "Filters")]
        public bool OnlyMagicNumber { get; set; }

        [Parameter("Matching magic number", DefaultValue = 0, Group = "Filters")]
        public int MagicNumber { get; set; }

        [Parameter("Modify only trades with the following comment", DefaultValue = false, Group = "Filters")]
        public bool OnlyWithComment { get; set; }

        [Parameter("Matching comment", DefaultValue = "", Group = "Filters")]
        public string MatchingComment { get; set; }

        [Parameter("Apply to pending orders too?", DefaultValue = false, Group = "Filters")]
        public bool ApplyToPending { get; set; }

        [Parameter("Price to use for SL/TP setting", DefaultValue = PriceType.Open, Group = "Execution")]
        public PriceType PriceTypeParam { get; set; }

        [Parameter("Process each position/order only once?", DefaultValue = true, Group = "Execution")]
        public bool ProcessOnceOnly { get; set; }

        [Parameter("Check interval in seconds", DefaultValue = 1, Group = "Execution")]
        public int CheckIntervalSeconds { get; set; }

        [Parameter("Enable robot?", DefaultValue = false, Group = "Execution")]
        public bool InputEnableRobot { get; set; }

        [Parameter("Show graphical panel", DefaultValue = true, Group = "Control panel")]
        public bool ShowPanel { get; set; }

        [Parameter("Expert name (to name the objects)", DefaultValue = "SLTP", Group = "Control panel")]
        public string ExpertName { get; set; }

        [Parameter("Horizontal spacing for the control panel", DefaultValue = 20, Group = "Control panel")]
        public int Xoff { get; set; }
        
        [Parameter("Vertical spacing for the control panel", DefaultValue = 20, Group = "Control panel")]
        public int Yoff { get; set; }
        
        [Parameter("Chart Corner", DefaultValue = VerticalAlignment.Top, Group = "Control panel")]
        public VerticalAlignment ChartCornerV { get; set; }
        
        [Parameter("Chart Corner", DefaultValue = HorizontalAlignment.Left, Group = "Control panel")]
        public HorizontalAlignment ChartCornerH { get; set; }

        [Parameter("Font Size", DefaultValue = 10, Group = "Control Panel")]
        public int FontSize { get; set; }

        // Global variables.
        private bool EnableRobot; // Main enable/disable flag.
        private HashSet<int> ProcessedPositions = new HashSet<int>();  // Set to store processed position IDs.
        private HashSet<int> ProcessedOrders = new HashSet<int>(); // Set to store processed order IDs.
        private DateTime LastCheckTime; // For processed positions/orders cleanup.

        // Panel variables.
        private TextBlock PanelLabel;
        private Button PanelEnableDisable;
        private StackPanel MainPanel;
        private string PanelBaseName = "";
        private string PanelLabelName = "";
        private string PanelEnableDisableName = "";

        protected override void OnStart()
        {
            EnableRobot = InputEnableRobot;

            // Initialize panel variables.
            PanelBaseName = ExpertName + "-P-BAS";
            PanelLabelName = ExpertName + "-P-LAB";
            PanelEnableDisableName = ExpertName + "-P-ENADIS";

            // Clean any existing panel objects.
            CleanPanel();

            // Draw panel if enabled.
            if (ShowPanel) DrawPanel();

            // Set up timer.
            Timer.Start(TimeSpan.FromSeconds(CheckIntervalSeconds));
        }

        protected override void OnTimer()
        {
            // Update panel if enabled.
            if (ShowPanel) DrawPanel();

            // Only process if enabled.
            if (!EnableRobot) return;

            // Process positions.
            ProcessPositions();

            // Clean up closed positions from the set periodically.
            if (ProcessOnceOnly && ProcessedPositions.Count > 0 && 
                (Server.Time - LastCheckTime).TotalSeconds > CheckIntervalSeconds * 10)
            {
                CleanupProcessedPositions();
            }

            // Process pending orders if enabled.
            if (ApplyToPending)
            {
                ProcessPendingOrders();
                // Clean up deleted orders from the set periodically.
                if (ProcessOnceOnly && ProcessedOrders.Count > 0 && 
                    (Server.Time - LastCheckTime).TotalSeconds > CheckIntervalSeconds * 10)
                {
                    CleanupProcessedOrders();
                }
            }
        }

        private void ProcessPositions()
        {
            var positions = Positions.ToList();
            
            foreach (var position in positions)
            {
                // Check if already processed.
                if (ProcessOnceOnly && ProcessedPositions.Contains(position.Id))
                    continue;

                // Check filters.
                if (!PassesPositionFilters(position))
                    continue;

                // Process the position.
                if (ModifyPosition(position))
                {
                    // Mark as processed if successful.
                    if (ProcessOnceOnly)
                    {
                        ProcessedPositions.Add(position.Id);
                    }
                }
            }
        }

        private void ProcessPendingOrders()
        {
            var orders = PendingOrders.ToList();
            
            foreach (var order in orders)
            {
                // Check if already processed.
                if (ProcessOnceOnly && ProcessedOrders.Contains(order.Id))
                    continue;
                    

                // Check filters.
                if (!PassesOrderFilters(order))
                    continue;

                // Process the order.
                if (ModifyOrder(order))
                {
                    // Mark as processed if successful.
                    if (ProcessOnceOnly)
                    {
                        ProcessedOrders.Add(order.Id);
                    }
                }
            }
        }

        private bool PassesPositionFilters(Position position)
        {
            // Check order type filter.
            if (OrderTypeFilter == OrderTypes.Sell && position.TradeType == TradeType.Buy)
                return false;
            if (OrderTypeFilter == OrderTypes.Buy && position.TradeType == TradeType.Sell)
                return false;

            // Check symbol filter.
            if (CurrentSymbolOnly && position.SymbolName != Symbol.Name)
                return false;

            // Check magic number filter (using label as magic number in cTrader).
            if (OnlyMagicNumber)
            {
                if (string.IsNullOrEmpty(position.Label) || !position.Label.Contains(MagicNumber.ToString()))
                    return false;
            }

            // Check comment filter.
            if (OnlyWithComment && position.Comment != MatchingComment)
                return false;

            return true;
        }

        private bool PassesOrderFilters(PendingOrder order)
        {
            // Check order type filter.
            if (OrderTypeFilter == OrderTypes.Sell && order.TradeType == TradeType.Buy)
                return false;
            if (OrderTypeFilter == OrderTypes.Buy && order.TradeType == TradeType.Sell)
                return false;

            // Check symbol filter.
            if (CurrentSymbolOnly && order.SymbolName != Symbol.Name)
                return false;

            // Check magic number filter (using label as magic number in cTrader).
            if (OnlyMagicNumber)
            {
                if (string.IsNullOrEmpty(order.Label) || !order.Label.Contains(MagicNumber.ToString()))
                    return false;
            }

            // Check comment filter.
            if (OnlyWithComment && order.Comment != MatchingComment)
                return false;

            return true;
        }

        private bool ModifyPosition(Position position)
        {
            var symbol = Symbols.GetSymbol(position.SymbolName);
            double price;
            double? stopLossPrice = null;
            double? takeProfitPrice = null;

            // Calculate SL/TP based on position type.
            if (position.TradeType == TradeType.Buy)
            {
                CalculateBuySLTP(symbol, position, out price, out stopLossPrice, out takeProfitPrice);
            }
            else
            {
                CalculateSellSLTP(symbol, position, out price, out stopLossPrice, out takeProfitPrice);
            }

            // Avoid modifying existing SL/TP if overwriting isn't allowed.
            if (!OverwriteExistingSL && position.StopLoss.HasValue) stopLossPrice = position.StopLoss.Value;
            if (!OverwriteExistingTP && position.TakeProfit.HasValue) takeProfitPrice = position.TakeProfit.Value;

            // Check if modification is needed.
            bool needsModification = false;
            
            if (stopLossPrice.HasValue && (!position.StopLoss.HasValue || 
                Math.Abs(stopLossPrice.Value - position.StopLoss.Value) > symbol.PipSize / 2))
            {
                needsModification = true;
            }
            
            if (takeProfitPrice.HasValue && (!position.TakeProfit.HasValue || 
                Math.Abs(takeProfitPrice.Value - position.TakeProfit.Value) > symbol.PipSize / 2))
            {
                needsModification = true;
            }

            if (!needsModification)
                return false;

            var result = ModifyPosition(position, stopLossPrice, takeProfitPrice, ProtectionType.Absolute);
            if (result.IsSuccessful)
            {
                Print($"Position #{position.Id} modified: SL={stopLossPrice} TP={takeProfitPrice}");
                return true;
            }
            else
            {
                Print($"Failed to modify position #{position.Id}: {result.Error}");
                return false;
            }
        }

        private bool ModifyOrder(PendingOrder order)
        {
            var symbol = Symbols.GetSymbol(order.SymbolName);
            double price;
            double? stopLossPrice = null;
            double? takeProfitPrice = null;

            // Calculate SL/TP based on order type.
            if (order.TradeType == TradeType.Buy)
            {
                CalculateBuyOrderSLTP(symbol, order, out price, out stopLossPrice, out takeProfitPrice);
            }
            else
            {
                CalculateSellOrderSLTP(symbol, order, out price, out stopLossPrice, out takeProfitPrice);
            }

            // Avoid modifying existing SL/TP if overwriting isn't allowed.
            if (!OverwriteExistingSL && order.StopLoss.HasValue) stopLossPrice = order.StopLoss.Value;
            if (!OverwriteExistingTP && order.TakeProfit.HasValue) takeProfitPrice = order.TakeProfit.Value;

            // Check if modification is needed.
            bool needsModification = false;
            
            if (stopLossPrice.HasValue && (!order.StopLoss.HasValue || 
                Math.Abs(stopLossPrice.Value - order.StopLoss.Value) > 0.1))
            {
                needsModification = true;
            }
            
            if (takeProfitPrice.HasValue && (!order.TakeProfit.HasValue || 
                Math.Abs(takeProfitPrice.Value - order.TakeProfit.Value) > 0.1))
            {
                needsModification = true;
            }

            if (!needsModification)
                return false;

            var result = ModifyPendingOrder(order, order.TargetPrice, stopLossPrice, takeProfitPrice, ProtectionType.Absolute);
            if (result.IsSuccessful)
            {
                Print($"Order {order.Label} modified: SL={stopLossPrice} pips TP={takeProfitPrice} pips");
                return true;
            }
            else
            {
                Print($"Failed to modify order {order.Label}: {result.Error}");
                return false;
            }
        }

        private void CalculateBuySLTP(Symbol symbol, Position position, out double price, 
                                      out double? stopLossPrice, out double? takeProfitPrice)
        {
            if (PriceTypeParam == PriceType.Current)
            {
                price = symbol.Bid;
            }
            else
            {
                price = position.EntryPrice;
            }

            // Calculate Stop-loss price.
            if (StopLossType == SLType.Unchanged)
            {
                stopLossPrice = position.StopLoss;
            }
            else if (StopLossType == SLType.Level)
            {
                stopLossPrice = StopLoss;
            }
            else if (StopLossType == SLType.Points && StopLoss > 0)
            {
                stopLossPrice = price - StopLoss * symbol.PipSize;
            }
            else
            {
                stopLossPrice = null;
            }

            // Calculate Take-profit price.
            if (TakeProfitType == TPType.Unchanged)
            {
                takeProfitPrice = position.TakeProfit;
            }
            else if (TakeProfitType == TPType.Level)
            {
                takeProfitPrice = TakeProfit;
            }
            else if (TakeProfitType == TPType.Points && TakeProfit > 0)
            {
                takeProfitPrice = price + TakeProfit * symbol.PipSize;
            }
            else if (TakeProfitType == TPType.Percentage && stopLossPrice.HasValue)
            {
                double slDistance = position.EntryPrice - stopLossPrice.Value;
                if (slDistance > 0)
                {
                    takeProfitPrice = price + slDistance * TakeProfit / 100;
                }
                else
                {
                    takeProfitPrice = null;
                }
            }
            else
            {
                takeProfitPrice = null;
            }
        }

        private void CalculateSellSLTP(Symbol symbol, Position position, out double price,
                                       out double? stopLossPrice, out double? takeProfitPrice)
        {
            if (PriceTypeParam == PriceType.Current)
            {
                price = symbol.Ask;
            }
            else
            {
                price = position.EntryPrice;
            }

            // Calculate Stop-loss price.
            if (StopLossType == SLType.Unchanged)
            {
                stopLossPrice = position.StopLoss;
            }
            else if (StopLossType == SLType.Level)
            {
                stopLossPrice = StopLoss;
            }
            else if (StopLossType == SLType.Points && StopLoss > 0)
            {
                stopLossPrice = price + StopLoss * symbol.PipSize;
            }
            else
            {
                stopLossPrice = null;
            }

            // Calculate Take-profit price.
            if (TakeProfitType == TPType.Unchanged)
            {
                takeProfitPrice = position.TakeProfit;
            }
            else if (TakeProfitType == TPType.Level)
            {
                takeProfitPrice = TakeProfit;
            }
            else if (TakeProfitType == TPType.Points && TakeProfit > 0)
            {
                takeProfitPrice = price - TakeProfit * symbol.PipSize;
            }
            else if (TakeProfitType == TPType.Percentage && stopLossPrice.HasValue)
            {
                double slDistance = stopLossPrice.Value - position.EntryPrice;
                if (slDistance > 0)
                {
                    takeProfitPrice = price - slDistance * TakeProfit / 100;
                }
                else
                {
                    takeProfitPrice = null;
                }
            }
            else
            {
                takeProfitPrice = null;
            }
        }

        private void CalculateBuyOrderSLTP(Symbol symbol, PendingOrder order, out double price,
                                           out double? stopLossPrice, out double? takeProfitPrice)
        {
            if (PriceTypeParam == PriceType.Current)
            {
                price = symbol.Bid;
            }
            else
            {
                price = order.TargetPrice;
            }

            // Calculate Stop-loss price.
            if (StopLossType == SLType.Unchanged)
            {
                stopLossPrice = order.StopLoss;
            }
            else if (StopLossType == SLType.Level)
            {
                stopLossPrice = StopLoss;
            }
            else if (StopLossType == SLType.Points && StopLoss > 0)
            {
                stopLossPrice = price - StopLoss * symbol.PipSize;
            }
            else
            {
                stopLossPrice = null;
            }

            // Calculate Take-profit price.
            if (TakeProfitType == TPType.Unchanged)
            {
                takeProfitPrice = order.TakeProfit;
            }
            else if (TakeProfitType == TPType.Level)
            {
                takeProfitPrice = TakeProfit;
            }
            else if (TakeProfitType == TPType.Points && TakeProfit > 0)
            {
                takeProfitPrice = price + TakeProfit * symbol.PipSize;;
            }
            else if (TakeProfitType == TPType.Percentage && stopLossPrice.HasValue)
            {
                double slDistance = order.TargetPrice - stopLossPrice.Value;
                if (slDistance > 0)
                {
                    takeProfitPrice = price + slDistance * TakeProfit / 100;
                }
                else
                {
                    takeProfitPrice = null;
                }
            }
            else
            {
                takeProfitPrice = null;
            }
        }

        private void CalculateSellOrderSLTP(Symbol symbol, PendingOrder order, out double price,
                                            out double? stopLossPrice, out double? takeProfitPrice)
        {
            if (PriceTypeParam == PriceType.Current)
            {
                price = symbol.Ask;
            }
            else
            {
                price = order.TargetPrice;
            }

            // Calculate Stop-loss price.
            if (StopLossType == SLType.Unchanged)
            {
                stopLossPrice = order.StopLoss;
            }
            else if (StopLossType == SLType.Level)
            {
                stopLossPrice = StopLoss;
            }
            else if (StopLossType == SLType.Points && StopLoss > 0)
            {
                stopLossPrice = price + StopLoss * symbol.PipSize;
            }
            else
            {
                stopLossPrice = null;
            }

            // Calculate Take-profit price.
            if (TakeProfitType == TPType.Unchanged)
            {
                takeProfitPrice = order.TakeProfit;
            }
            else if (TakeProfitType == TPType.Level)
            {
                takeProfitPrice = TakeProfit;
            }
            else if (TakeProfitType == TPType.Points && TakeProfit > 0)
            {
                takeProfitPrice = price - TakeProfit * symbol.PipSize;;
            }
            else if (TakeProfitType == TPType.Percentage && stopLossPrice.HasValue)
            {
                double slDistance = stopLossPrice.Value - order.TargetPrice;
                if (slDistance > 0)
                {
                    takeProfitPrice = price - slDistance * TakeProfit / 100;
                }
                else
                {
                    takeProfitPrice = null;
                }
            }
            else
            {
                takeProfitPrice = null;
            }
        }

        private void CleanupProcessedPositions()
        {
            var currentPositions = Positions.Select(p => p.Id).ToHashSet();
            ProcessedPositions.RemoveWhere(id => !currentPositions.Contains(id));
            LastCheckTime = Server.Time;
        }

        private void CleanupProcessedOrders()
        {
            var currentOrders = PendingOrders.Select(o => o.Id).ToHashSet();
            ProcessedOrders.RemoveWhere(Id => !currentOrders.Contains(Id));
            LastCheckTime = Server.Time;
        }

        private void DrawPanel()
        {
            int LeftOff = 0;
            int TopOff = 0;
            int RightOff = 0;
            int BottomOff = 0;
            if (ChartCornerH == HorizontalAlignment.Left) LeftOff = Xoff;
            else if (ChartCornerH == HorizontalAlignment.Right) RightOff = Xoff;
            if (ChartCornerV == VerticalAlignment.Top) TopOff = Yoff;
            else if (ChartCornerV == VerticalAlignment.Bottom) BottomOff = Yoff;
            MainPanel = new StackPanel 
            {
                Orientation = Orientation.Vertical,
                HorizontalAlignment = ChartCornerH,
                VerticalAlignment = ChartCornerV,
                Width = 200,
                MinHeight = 45,
                Margin = new Thickness(LeftOff, TopOff, RightOff, BottomOff),
                BackgroundColor = Color.White,
                Opacity = 0.9
            };

            PanelLabel = new TextBlock 
            {
                Text = "Fixed SL/TP",
                ForegroundColor = Color.Navy,
                BackgroundColor = Color.Khaki,
                Width = 198,
                MinHeight = 20,
                FontSize = FontSize + 2,
                Margin = 1,
                Padding = 2,
                TextAlignment = TextAlignment.Center
            };

            PanelEnableDisable = new Button 
            {
                Text = EnableRobot ? "ROBOT ENABLED" : "ROBOT DISABLED",
                ForegroundColor = Color.White,
                BackgroundColor = EnableRobot ? Color.DarkGreen : Color.DarkRed,
                Width = 198,
                MinHeight = 22,
                FontSize = FontSize,
                CornerRadius = 0,
                HorizontalAlignment = HorizontalAlignment.Center
            };
            
            PanelEnableDisable.Click += ChangeTrailingEnabled;

            MainPanel.AddChild(PanelLabel);
            MainPanel.AddChild(PanelEnableDisable);
            
            Chart.AddControl(MainPanel);
        }

        private void UpdatePanel()
        {
            if (PanelEnableDisable != null)
            {
                PanelEnableDisable.Text = EnableRobot ? "ROBOT ENABLED" : "ROBOT DISABLED";
                PanelEnableDisable.BackgroundColor = EnableRobot ? Color.DarkGreen : Color.DarkRed;
            }
        }

        private void CleanPanel()
        {
            if (MainPanel != null)
            {
                Chart.RemoveControl(MainPanel);
            }
        }

        private void ChangeTrailingEnabled(ButtonClickEventArgs obj)
        {
            if (EnableRobot == false)
            {
                EnableRobot = true;
            }
            else 
            {
                EnableRobot = false;
            }
            UpdatePanel();
        }
    }
}