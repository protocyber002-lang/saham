# Config.ps1 - konstanta global game (ASCII-safe)
Set-StrictMode -Version 2.0

$Global:Config = @{
    SaveVersion        = 1
    OfflineCapHours    = 8.0      # maksimal offline dihitung
    OfflineMinSeconds  = 5.0      # di bawah ini diabaikan (biar tidak spam)
    AutosaveInterval   = 30.0     # detik
    RenderThrottle     = 0.99     # detik
    FrameClampSeconds  = 5.0      # clamp delta per frame (anti-freeze)

    ClickerAutoPerLvl  = 0.2      # auto-rate per level clicker
    ClickerUpgradeBase = 10.0     # biaya awal upgrade
    ClickerUpgradeMul  = 1.15     # multiplier biaya

    MathTimeoutSec     = 15
    MathBuffDurationSec= 30
    MathBuffPerLevel   = 0.5
    MathFastBonusSec   = 5.0      # di bawah ini = reward kali (MathFastBonusMult)
    MathFastBonusMult  = 10.0      # multiplier reward
    MathClickBuffMult        = 3.0  # bonus N kali perklik jika jawaban math benar
    MathClickBuffDurationSec = 15.0 # bonus N kali perklik berlaku selama itu
    MathClickBuffPerCorrect  = 1.0  # bonus N kali perklik untuk N soal benar

    AssetHooksEnabled  = $true

    # --- SERVER ---
    ServerPort = 8999

    # --- BUFF BELI SAHAM (Auto Income) ---
    StockBuyBuff10_Qty  = 10
    StockBuyBuff10_Mult = 3.0
    StockBuyBuff10_Sec  = 5

    StockBuyBuff50_Qty  = 50
    StockBuyBuff50_Mult = 3.0
    StockBuyBuff50_Sec  = 10

    StockBuyBuff100_Qty = 100
    StockBuyBuff100_Mult= 3.0
    StockBuyBuff100_Sec = 15

    StockBuyBuff200_Qty = 200
    StockBuyBuff200_Mult= 4.0
    StockBuyBuff200_Sec = 15

    StockBuyBuff400_Qty = 400
    StockBuyBuff400_Mult= 4.0
    StockBuyBuff400_Sec = 20

    # --- AUTO-BOT SAHAM ---
    AutoBotEcoDurationMin = 10.0        # Durasi paket ekonomis (menit)
    AutoBotEcoCost        = 1000000.0   # Harga paket ekonomis
    AutoBotVipCost        = 1000000000.0# Harga prestige (1 Miliar)
    AutoBotVipDurationHr  = 24.0        # Durasi paket VIP (jam)
    AutoBotDefaultBuyPct  = -5.0        # Trigger beli default (%)
    AutoBotDefaultSellPct = -50.0       # Trigger jual default (%)
    AutoBotBuyQty         = 10          # Jumlah beli
    AutoBotSellRemain     = 1           # Sisa saham setelah jual

    # --- AUTO PILOT SAHAM ---
    AutoBuyerUnlockCost = 500000.0    # Harga alat Auto-Buy (misal 500rb)
    AutoSellerUnlockCost = 500000.0   # Harga alat Auto-Sell
    AutoBuyTriggerPct = -5.0          # Beli otomatis jika harga turun 5% dari harga beli
    AutoBuyQuantity = 10              # Jumlah lembar yang dibeli bot
    AutoSellTriggerPct = -50.0        # Jual otomatis jika rugi 50%
    AutoSellRemaining = 1             # Sisa saham setelah dijual bot

    # --- TAB KERJA: MATEMATIKA ---
    MathWorkAutoMult = 3.0        # Bonus Auto Income 3x
    MathWorkAutoSec  = 20.0       # Selama 20 detik
    MathWorkFastBonusClickMult = 5.0 # Bonus Click Gain 5x jika benar < 5 detik
    MathWorkFastBonusClickSec  = 15.0 # Selama 15 detik
    MathWorkRewardBase = 1000.0   # Bonus langsung (1000 x level)

    # --- TAB KERJA: DEVELOPER BANGUNAN ---
    BuildMaterialCost = 500000.0  # Harga bahan bangunan (lama, dipakai migrasi)
    BuildLaborCost    = 200000.0  # Honor tenaga kerja (lama, dipakai migrasi)
    BuildWaitMinutes  = 30.0      # Waktu tunggu bangunan (menit, lama)
    BuildSellMarkupPct = 50.0     # Markup harga jual rumah (50%)

    # --- JENIS RUMAH (Developer Bangunan) ---
    HouseType21_Cost  = 500000.0
    HouseType21_Wait  = 20.0      # menit
    HouseType45_Cost  = 1000000.0
    HouseType45_Wait  = 30.0
    HouseType90_Cost  = 2500000.0
    HouseType90_Wait  = 45.0
    HouseType120_Cost = 5000000.0
    HouseType120_Wait = 60.0
}