import 'package:flutter/widgets.dart';

class AppStrings {
  const AppStrings(this.locale);
  final Locale locale;
  bool get isPersian => locale.languageCode == 'fa';

  String get appName => 'Connecso';
  String get noProfile => isPersian
      ? 'برای شروع اشتراک خود را وارد کنید'
      : 'Import a subscription to get started';
  String get pasteClipboard =>
      isPersian ? 'وارد کردن از کلیپ‌بورد' : 'Paste from Clipboard';
  String get scanQr => isPersian ? 'اسکن QR' : 'Scan QR';
  String get openCamera => isPersian ? 'باز کردن دوربین' : 'Open Camera';
  String get chooseImage => isPersian ? 'انتخاب تصویر' : 'Choose Image';
  String get connect => isPersian ? 'برای اتصال بزنید' : 'Tap to connect';
  String get connected => isPersian ? 'متصل' : 'Connected';
  String get connecting => isPersian ? 'در حال اتصال…' : 'Connecting…';
  String get cancelConnection => isPersian ? 'لغو اتصال' : 'Cancel connection';
  String get reconnecting => isPersian ? 'اتصال دوباره…' : 'Reconnecting…';
  String get disconnecting => isPersian ? 'در حال قطع…' : 'Disconnecting…';
  String get disconnected => isPersian ? 'قطع' : 'Disconnected';
  String get failed => isPersian ? 'اتصال برقرار نشد' : 'Failed to connect';
  String get vpnPermissionFailure => isPersian
      ? 'مجوز اتصال وی‌پی‌ان داده نشد.'
      : 'Android VPN permission was not granted.';
  String get noUsableNodes => isPersian
      ? 'سرور قابل‌استفاده‌ای در اشتراک پیدا نشد.'
      : 'No usable servers were found in this subscription.';
  String get xrayUnavailable => isPersian
      ? 'هستهٔ Xray در دسترس نیست یا نتوانست اجرا شود.'
      : 'Xray is unavailable or could not start.';
  String get connectivityVerificationFailed => isPersian
      ? 'تونل ساخته شد، اما دسترسی واقعی اینترنت تأیید نشد.'
      : 'The tunnel started, but internet access could not be verified.';
  String get destination =>
      isPersian ? 'موقعیت خروج وی‌پی‌ان' : 'VPN Exit Location';
  String get unknownLocation => isPersian ? 'نامشخص' : 'Unknown';
  String locationName(String country, String city) {
    final localizedCountry = isPersian
        ? const {
                'Germany': 'آلمان',
                'Netherlands': 'هلند',
                'United Kingdom': 'بریتانیا',
                'France': 'فرانسه',
                'Turkey': 'ترکیه',
                'United States': 'ایالات متحده',
                'Italy': 'ایتالیا',
                'Poland': 'لهستان',
                'Finland': 'فنلاند',
                'Japan': 'ژاپن',
                'Canada': 'کانادا',
              }[country] ??
              country
        : country;
    final localizedCity = isPersian
        ? const {
                'Frankfurt': 'فرانکفورت',
                'Amsterdam': 'آمستردام',
                'London': 'لندن',
                'Paris': 'پاریس',
                'Istanbul': 'استانبول',
                'New York': 'نیویورک',
                'Milan': 'میلان',
                'Warsaw': 'ورشو',
                'Helsinki': 'هلسینکی',
                'Tokyo': 'توکیو',
                'Toronto': 'تورنتو',
              }[city] ??
              city
        : city;
    if (localizedCountry.isEmpty || localizedCountry == 'Unknown') {
      return localizedCity.isEmpty ? unknownLocation : localizedCity;
    }
    return localizedCity.isEmpty
        ? localizedCountry
        : '$localizedCountry · $localizedCity';
  }

  String get ping => isPersian ? 'پینگ' : 'Ping';
  String get refreshPing =>
      isPersian ? 'برای تازه‌سازی پینگ لمس کنید' : 'Tap to refresh ping';
  String get stability => isPersian ? 'پایداری' : 'Stability';
  String get thisSession => isPersian ? 'این نشست' : 'This Session';
  String get sessionTotal => isPersian ? 'مجموع نشست' : 'Session total';
  String get downloaded => isPersian ? 'دریافت‌شده' : 'Downloaded';
  String get uploaded => isPersian ? 'ارسال‌شده' : 'Uploaded';
  String get currentUsage => isPersian ? 'مصرف فعلی' : 'Current usage';
  String get download => isPersian ? 'دریافت' : 'Download';
  String get upload => isPersian ? 'ارسال' : 'Upload';
  String get totalUsage => isPersian ? 'مصرف کل' : 'Total Usage';
  String get remaining => isPersian ? 'باقی‌مانده' : 'Remaining';
  String get unlimited => isPersian ? 'نامحدود' : 'Unlimited';
  String get expired => isPersian ? 'منقضی‌شده' : 'Expired';
  String expiresOn(String date) => isPersian ? 'انقضا $date' : 'Expires $date';
  String get expires => isPersian ? 'تاریخ انقضا' : 'Expires';
  String get noExpiry => isPersian ? 'بدون تاریخ انقضا' : 'No expiry';
  String get subscription => isPersian ? 'اشتراک' : 'Subscription';
  String get unavailable => isPersian ? 'نامشخص' : 'Unavailable';
  String get splitTunneling =>
      isPersian ? 'جداسازی برنامه‌های ایرانی' : 'Split Tunneling';
  String get splitTunnelingSecondary => isPersian
      ? 'مسیریابی جداگانهٔ برنامه‌ها'
      : 'Route selected apps separately';
  String get stable => isPersian ? 'پایدار' : 'Stable';
  String get unstable => isPersian ? 'ناپایدار' : 'Unstable';
  String get stabilityUnavailable =>
      isPersian ? 'پایداری نامشخص' : 'Stability unavailable';
  String get settings => isPersian ? 'تنظیمات' : 'Settings';
  String get language => isPersian ? 'زبان' : 'Language';
  String get theme => isPersian ? 'پوسته' : 'Theme';
  String get english => 'English';
  String get persian => 'فارسی';
  String get light => isPersian ? 'روشن' : 'Light';
  String get dark => isPersian ? 'تیره' : 'Dark';
  String get close => isPersian ? 'بستن' : 'Close';
  String get permissionNeeded => isPersian
      ? 'مجوز اتصال وی‌پی‌ان لازم است.'
      : 'VPN permission is required.';
  String get noClipboard => isPersian
      ? 'متن اشتراک در کلیپ‌بورد پیدا نشد.'
      : 'No subscription text was found in the clipboard.';
  String get importFailed => isPersian
      ? 'وارد کردن اشتراک ناموفق بود.'
      : 'Subscription import failed.';
  String get scanFailed =>
      isPersian ? 'کد QR معتبری پیدا نشد.' : 'No valid QR code was found.';
  String get installedApps =>
      isPersian ? 'برنامه‌های نصب‌شده' : 'Installed apps';
  String get splitInfo => isPersian
      ? 'برنامه‌های انتخاب‌شده از VPN استفاده نمی‌کنند.'
      : 'Selected apps bypass the VPN.';
  String get selectedAppsUseVpn => isPersian ? 'عبور از پراکسی' : 'Use Proxy';
  String get selectedAppsBypassVpn => isPersian ? 'دور زدن پراکسی' : 'Bypass';
  String get splitOff => isPersian ? 'خاموش' : 'OFF';
  String get splitChangesTitle =>
      isPersian ? 'تغییرات ذخیره شوند؟' : 'Save changes?';
  String get discard => isPersian ? 'لغو تغییرات' : 'Discard';
  String get selectAll => isPersian ? 'انتخاب همه' : 'Select all';
  String get invertSelection => isPersian ? 'معکوس' : 'Invert';
  String get clearSelection => isPersian ? 'پاک‌کردن انتخاب' : 'Clear selected';
  String get splitStagedInfo => isPersian
      ? 'این انتخاب‌ها ذخیره می‌شوند و با هستهٔ اتصال اندروید اعمال خواهند شد.'
      : 'Selections are saved and will be applied by the Android VPN runtime.';
  String get save => isPersian ? 'ذخیره' : 'Save';
  String get saveFailed =>
      isPersian ? 'ذخیرهٔ تنظیمات ناموفق بود.' : 'Settings could not be saved.';
  String get systemApp => isPersian ? 'برنامهٔ سیستمی' : 'System app';
  String get searchApplications =>
      isPersian ? 'جست‌وجوی برنامه‌ها' : 'Search apps';
  String get showSystemApps =>
      isPersian ? 'نمایش برنامه‌های سیستمی' : 'Show system apps';
  String get hideSystemApps =>
      isPersian ? 'پنهان‌کردن برنامه‌های سیستمی' : 'Hide system apps';
  String get exportSplitList =>
      isPersian ? 'خروجی فهرست در کلیپ‌بورد' : 'Export list to clipboard';
  String get importSplitList =>
      isPersian ? 'ورود فهرست از کلیپ‌بورد' : 'Import list from clipboard';
  String get splitListExported => isPersian
      ? 'فهرست مسیریابی در کلیپ‌بورد کپی شد.'
      : 'Split tunneling list copied to clipboard.';
  String get splitListImported =>
      isPersian ? 'فهرست مسیریابی وارد شد.' : 'Split tunneling list imported.';
  String get splitListImportFailed => isPersian
      ? 'فهرست معتبر CONNECSO در کلیپ‌بورد پیدا نشد.'
      : 'No valid CONNECSO split tunneling list was found.';
  String get noApplicationsFound =>
      isPersian ? 'برنامه‌ای پیدا نشد.' : 'No apps found.';
  String get retry => isPersian ? 'تلاش دوباره' : 'Try again';
  String get subscriptions => isPersian ? 'اشتراک‌ها' : 'Subscriptions';
  String get addSubscription =>
      isPersian ? 'افزودن اشتراک' : 'Add subscription';
  String get rename => isPersian ? 'تغییر نام' : 'Rename';
  String get deactivate => isPersian ? 'خروج از اشتراک فعال' : 'Sign out';
  String get deactivateTitle =>
      isPersian ? 'خروج از این اشتراک؟' : 'Sign out of this subscription?';
  String get deactivateMessage => isPersian
      ? 'اشتراک از حساب فعال خارج می‌شود اما در فهرست ذخیره می‌ماند.'
      : 'This subscription will be deactivated and kept in your saved list.';
  String get cancel => isPersian ? 'لغو' : 'Cancel';
  String get subscriptionName => isPersian ? 'نام اشتراک' : 'Subscription name';
  String get savedSubscriptionHint => isPersian
      ? 'اشتراک‌های ذخیره‌شده را از تنظیمات انتخاب کنید یا اشتراک تازه‌ای بیفزایید.'
      : 'Choose a saved subscription in Settings or add a new one.';
  String get noSavedSubscriptions =>
      isPersian ? 'اشتراکی ذخیره نشده است.' : 'No saved subscriptions.';
  String get activeSubscription => isPersian ? 'فعال' : 'Active';
  String get savedSubscription => isPersian ? 'ذخیره‌شده' : 'Saved';
  String get editSubscription =>
      isPersian ? 'ویرایش اشتراک' : 'Edit subscription';
  String get subscriptionLink =>
      isPersian ? 'لینک اشتراک' : 'Subscription link';
  String get copyLink => isPersian ? 'کپی لینک' : 'Copy link';
  String get autoRefresh => isPersian ? 'به‌روزرسانی خودکار' : 'Auto Refresh';
  String get refreshInterval =>
      isPersian ? 'فاصلهٔ به‌روزرسانی' : 'Refresh Interval';
  String get linkCopied => isPersian ? 'لینک کپی شد' : 'Link copied';
  String get refreshSubscription =>
      isPersian ? 'تازه‌سازی اشتراک' : 'Refresh subscription';
  String get subscriptionRefreshed => isPersian
      ? 'اشتراک با موفقیت به‌روزرسانی شد.'
      : 'Subscription refreshed successfully.';
  String get deleteSubscription =>
      isPersian ? 'حذف اشتراک' : 'Delete subscription';
  String deleteSubscriptionMessage(String name) => isPersian
      ? 'اشتراک «$name» از فهرست حذف شود؟'
      : 'Remove “$name” from the saved list?';
  String get delete => isPersian ? 'حذف' : 'Delete';
  String get pinSubscription => isPersian ? 'سنجاق‌کردن' : 'Pin subscription';
  String get unpinSubscription =>
      isPersian ? 'برداشتن سنجاق' : 'Unpin subscription';
  String get subscriptionActionFailed => isPersian
      ? 'انجام عملیات اشتراک ناموفق بود.'
      : 'The subscription action failed.';
  String get subscriptionDetails =>
      isPersian ? 'اطلاعات اشتراک' : 'Subscription details';
  String get supportLink => isPersian ? 'پشتیبانی' : 'Support';
  String get profileLink => isPersian ? 'پروفایل' : 'Profile';
  String get announcement => isPersian ? 'اعلان مدیر' : 'Admin announcement';
  String get noSubscriptionDetails => isPersian
      ? 'اطلاعات تکمیلی برای این اشتراک موجود نیست.'
      : 'No additional information is available for this subscription.';
  String get metadataCopied => isPersian ? 'لینک کپی شد.' : 'Link copied.';
  String get linkOpenFailed =>
      isPersian ? 'باز کردن لینک ممکن نشد.' : 'Could not open this link.';

  String status(String state) => switch (state) {
    'noProfile' => noProfile,
    'preparing' || 'connecting' || 'verifying' => connecting,
    'reconnecting' => reconnecting,
    'disconnecting' => disconnecting,
    'connected' => connected,
    'failed' => failed,
    _ => disconnected,
  };
}
