using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml;

namespace PhoneCentre;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Title = "PhoneCentre";
        SystemBackdrop = new MicaBackdrop();
        Info.Text = $"{RuntimeInformation.OSArchitecture} / {RuntimeInformation.ProcessArchitecture} / {RuntimeInformation.FrameworkDescription}";
    }
}
