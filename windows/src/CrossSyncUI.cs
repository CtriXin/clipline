using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Pegline
{
    /// Concise CrossSync settings & pairing window for Windows Clipline.
    sealed class SyncSettingsWindow : Window
    {
        static SyncSettingsWindow current;

        readonly CrossSync sync = CrossSync.Instance;
        readonly CheckBox enableBox = new CheckBox { Content = "开启跨设备同步", FontWeight = FontWeights.SemiBold };
        readonly Ellipse statusDot = new Ellipse { Width = 8, Height = 8, Margin = new Thickness(8, 0, 4, 0) };
        readonly TextBlock statusLabel = new TextBlock { FontSize = 12, Foreground = Brushes.Gray };
        readonly WrapPanel devicesPanel = new WrapPanel { Margin = new Thickness(0, 6, 0, 6) };
        readonly RadioButton clientRadio = new RadioButton { Content = "连接主机", Margin = new Thickness(0, 0, 14, 0) };
        readonly RadioButton hostRadio = new RadioButton { Content = "本机作主机（免服务器）" };
        readonly TextBlock guideLabel = new TextBlock { FontSize = 12, Foreground = Brushes.Gray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4) };
        readonly TextBlock feedbackLabel = new TextBlock { FontSize = 12, Foreground = new SolidColorBrush(Color.FromRgb(26, 127, 55)), Margin = new Thickness(0, 4, 0, 0) };
        readonly TextBox hubBox = new TextBox { Margin = new Thickness(0, 2, 0, 6) };
        readonly PasswordBox tokenBox = new PasswordBox { Margin = new Thickness(0, 2, 0, 6) };
        readonly TextBox deviceBox = new TextBox { Margin = new Thickness(0, 2, 0, 6) };
        readonly CheckBox imgBox = new CheckBox { Content = "同步图片（≤10MB）", Margin = new Thickness(0, 2, 0, 6) };
        bool loading;

        public static void ShowSingleton()
        {
            if (current != null)
            {
                current.Activate();
                return;
            }
            current = new SyncSettingsWindow();
            current.Closed += delegate { current = null; };
            current.Show();
        }

        SyncSettingsWindow()
        {
            Title = "Clipline 跨设备同步";
            Width = 460;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = new SolidColorBrush(Color.FromRgb(248, 249, 251));

            var root = new StackPanel { Margin = new Thickness(18) };

            // Top row: toggle + status dot
            var topRow = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            topRow.Children.Add(enableBox);
            topRow.Children.Add(statusDot);
            topRow.Children.Add(statusLabel);
            root.Children.Add(topRow);

            // Role selector
            var roleRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 4) };
            roleRow.Children.Add(clientRadio);
            roleRow.Children.Add(hostRadio);
            root.Children.Add(roleRow);

            // Online devices chips
            root.Children.Add(devicesPanel);

            // Primary action buttons
            var btnRow = new WrapPanel { Margin = new Thickness(0, 4, 0, 4) };
            var btnPaste = MakeBtn("粘贴配对码", () =>
            {
                try
                {
                    string clip = Clipboard.ContainsText() ? Clipboard.GetText() : "";
                    if (sync.ImportPairing(clip))
                    {
                        RefreshFromModel();
                        feedbackLabel.Text = "已配对并连接";
                    }
                    else feedbackLabel.Text = "剪贴板中没有有效的 clipsync:// 配对码";
                }
                catch (Exception) { feedbackLabel.Text = "读取剪贴板失败"; }
            });
            var btnCopy = MakeBtn("复制配对码", () =>
            {
                if (string.IsNullOrEmpty(sync.Token)) { feedbackLabel.Text = "请先配置或开启本机作主机"; return; }
                ClipboardCatcher.IgnoreNext();
                var data = new DataObject();
                data.SetText(sync.PairingCode, TextDataFormat.UnicodeText);
                Line.PutOnClipboard(data);
                feedbackLabel.Text = "已复制配对码，去另一台电脑粘贴即可";
            });
            var btnWeb = MakeBtn("打开网页端", () =>
            {
                try { Process.Start(sync.PairingWebURL); } catch (Exception) { }
            });
            var btnTs = MakeBtn("安装 Tailscale ↗", () =>
            {
                try { Process.Start("https://tailscale.com/download"); } catch (Exception) { }
            });
            btnRow.Children.Add(btnPaste);
            btnRow.Children.Add(btnCopy);
            btnRow.Children.Add(btnWeb);
            btnRow.Children.Add(btnTs);
            root.Children.Add(btnRow);

            root.Children.Add(guideLabel);
            root.Children.Add(feedbackLabel);

            // Collapsible connection details
            var details = new StackPanel { Margin = new Thickness(0, 6, 0, 0) };
            details.Children.Add(new TextBlock { Text = "Hub 地址（多地址用逗号分隔）", FontSize = 11.5, Foreground = Brushes.Gray });
            details.Children.Add(hubBox);
            details.Children.Add(new TextBlock { Text = "访问 Token", FontSize = 11.5, Foreground = Brushes.Gray });
            details.Children.Add(tokenBox);
            details.Children.Add(new TextBlock { Text = "本机设备名", FontSize = 11.5, Foreground = Brushes.Gray });
            details.Children.Add(deviceBox);
            details.Children.Add(imgBox);
            var btnApply = MakeBtn("保存并重连", SaveAndReconnect);
            details.Children.Add(btnApply);

            var expander = new Expander
            {
                Header = "连接设置",
                Margin = new Thickness(0, 8, 0, 0),
                IsExpanded = string.IsNullOrEmpty(sync.Token),
                Content = details
            };
            root.Children.Add(expander);

            Content = root;

            enableBox.Checked += (s, e) => { if (!loading) { sync.Enabled = true; RefreshStatus(); } };
            enableBox.Unchecked += (s, e) => { if (!loading) { sync.Enabled = false; RefreshStatus(); } };
            clientRadio.Checked += (s, e) => { if (!loading) { sync.HostMode = false; RefreshFromModel(); } };
            hostRadio.Checked += (s, e) => { if (!loading) { sync.HostMode = true; RefreshFromModel(); } };

            sync.Changed += OnSyncChanged;
            Closed += delegate { sync.Changed -= OnSyncChanged; };

            RefreshFromModel();
        }

        Button MakeBtn(string text, Action onClick)
        {
            var b = new Button { Content = text, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 6, 6) };
            b.Click += delegate { onClick(); };
            return b;
        }

        void SaveAndReconnect()
        {
            sync.HubURL = hubBox.Text;
            sync.Token = tokenBox.Password;
            sync.DeviceName = deviceBox.Text;
            sync.SyncImages = imgBox.IsChecked == true;
            sync.Restart();
            feedbackLabel.Text = "已保存并重连";
            RefreshStatus();
        }

        void OnSyncChanged()
        {
            Dispatcher.BeginInvoke(new Action(RefreshStatus));
        }

        void RefreshFromModel()
        {
            loading = true;
            enableBox.IsChecked = sync.Enabled;
            clientRadio.IsChecked = !sync.HostMode;
            hostRadio.IsChecked = sync.HostMode;
            hubBox.Text = sync.HostMode ? sync.ShareableHubURL : sync.HubURL;
            hubBox.IsEnabled = !sync.HostMode;
            tokenBox.Password = sync.Token;
            deviceBox.Text = sync.DeviceName;
            imgBox.IsChecked = sync.SyncImages;
            loading = false;
            RefreshStatus();
        }

        void RefreshStatus()
        {
            statusLabel.Text = sync.StatusSummary;
            switch (sync.State)
            {
                case SyncState.Connected: statusDot.Fill = new SolidColorBrush(Color.FromRgb(46, 160, 67)); break;
                case SyncState.Connecting: statusDot.Fill = Brushes.Orange; break;
                case SyncState.Error: statusDot.Fill = Brushes.Crimson; break;
                default: statusDot.Fill = Brushes.Gray; break;
            }

            devicesPanel.Children.Clear();
            foreach (var dev in sync.OnlineDevices)
            {
                var chip = new Border
                {
                    CornerRadius = new CornerRadius(10),
                    Background = new SolidColorBrush(Color.FromArgb(26, 9, 105, 218)),
                    Padding = new Thickness(8, 2, 8, 2),
                    Margin = new Thickness(0, 0, 6, 4),
                    Child = new TextBlock { Text = dev.Icon + " " + dev.Name, FontSize = 11.5 }
                };
                devicesPanel.Children.Add(chip);
            }

            if (sync.HostMode)
                guideLabel.Text = sync.HasTailscale
                    ? "已检测到 Tailscale：复制配对码粘贴到其他电脑即可互通。"
                    : "同 Wi-Fi 可直连；跨网建议装免费 Tailscale 组网。";
            else if (string.IsNullOrEmpty(sync.Token) || string.IsNullOrEmpty(sync.HubURL))
                guideLabel.Text = "在另一台电脑点「复制配对码」，再回这里点「粘贴配对码」。";
            else
                guideLabel.Text = "手机可用相机扫 Mac 端二维码，或点「打开网页端」查看同步记录。";
        }
    }
}
