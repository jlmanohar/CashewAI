import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/settingsContainers.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/functions.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/widgets/openBottomSheet.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:budget/widgets/categoryIcon.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/pages/addTransactionPage.dart';
import 'package:budget/pages/editWalletsPage.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:openai_dart/openai_dart.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:budget/widgets/framework/popupFramework.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/colors.dart';
import 'package:budget/widgets/textInput.dart';

const String defaultSystemPrompt = """
You are a transaction extraction assistant. Analyze the bank, credit card, or wallet SMS notification provided and extract transaction details.
You MUST return ONLY a raw JSON object and nothing else. Do not wrap the JSON in ```json ... ``` codeblocks or markdown.
If the SMS is a transaction notification, extract:
- "merchant": The name of the business, merchant, or person involved (e.g., "Walmart", "Netflix", "Uber", "John Doe").
- "amount": The transaction amount as a double (e.g. 45.20). Must be a positive number.
- "currency": The 3-letter currency code (e.g. "USD", "INR", "EUR", "VND", "GBP").
- "type": Either "debit" (for spent, paid, sent, debited, withdrawn, purchase) or "credit" (for received, credited, salary, refund, deposit).
- "note": A short, clear description summarizing the transaction.
- "timestamp": The exact date and time of the transaction mentioned in the SMS body, formatted as an ISO 8601 string (e.g., "2026-06-06T14:30:00"). If the transaction year is not specified, assume the year from the current reference time. If no transaction date or time is explicitly mentioned in the SMS body, return null.

Current reference time: {current_reference_time}

If the SMS is NOT a transaction notification (e.g. OTP, password reset, personal chat, marketing message), return an empty JSON object: {}
""";

class AiPage extends StatefulWidget {
  const AiPage({super.key});

  @override
  State<AiPage> createState() => AiPageState();
}

class AiPageState extends State<AiPage> {
  final GlobalKey<PageFrameworkState> pageState = GlobalKey();
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadProgressText = "";
  HttpClientRequest? _activeRequest;

  Future<void> _enterTextSettingBottomSheet({
    required BuildContext context,
    required String title,
    required String settingKey,
    required IconData icon,
    String? placeholder,
  }) async {
    await openBottomSheet(
      context,
      popupWithKeyboard: true,
      PopupFramework(
        title: title,
        child: SelectText(
          buttonLabel: "Save",
          icon: icon,
          setSelectedText: (_) {},
          nextWithInput: (text) {
            updateSettings(settingKey, text.trim(), updateGlobalState: false);
            setState(() {});
          },
          selectedText: appStateSettings[settingKey] ?? "",
          placeholder: placeholder ?? title,
          autoFocus: true,
        ),
      ),
    );
  }

  Future<void> _enterSystemPromptBottomSheet({
    required BuildContext context,
    required String title,
    required String settingKey,
    required String defaultPrompt,
  }) async {
    String currentPrompt = appStateSettings[settingKey] ?? "";
    if (currentPrompt.isEmpty) currentPrompt = defaultPrompt;

    final controller = TextEditingController(text: currentPrompt);

    await openBottomSheet(
      context,
      popupWithKeyboard: true,
      PopupFramework(
        title: title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextInput(
              labelText: "System Prompt",
              controller: controller,
              minLines: 5,
              maxLines: 15,
              autoFocus: true,
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: Button(
                    label: "Reset",
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    textColor: Theme.of(context).colorScheme.onSecondaryContainer,
                    onTap: () {
                      controller.text = defaultPrompt;
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Button(
                    label: "Save",
                    onTap: () {
                      updateSettings(settingKey, controller.text.trim(), updateGlobalState: false);
                      popRoute(context);
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _processAllSms() async {
    await triggerSmsAiSync(context, isAuto: false);
  }

  static Future<void> triggerSmsAiSync(BuildContext context, {bool isAuto = false}) async {
    print("DEBUG: triggerSmsAiSync entered. isAuto: $isAuto");
    if (getPlatform() != PlatformOS.isAndroid) {
      if (!isAuto) {
        openPopup(
          context,
          title: "Not Supported",
          description: "SMS processing is only supported on Android devices.",
          icon: Icons.warning_amber_rounded,
          onCancel: () => popRoute(context),
          onCancelLabel: "Ok",
        );
      }
      return;
    }

    PermissionStatus status = await Permission.sms.status;
    if (!status.isGranted) {
      if (!isAuto) {
        status = await Permission.sms.request();
      }
    }
    if (!status.isGranted) {
      if (!isAuto) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text("SMS permission is required to process transactions.")),
        );
      }
      return;
    }

    final SmsQuery query = SmsQuery();
    List<SmsMessage> messages = [];
    try {
      messages = await query.querySms(kinds: [SmsQueryKind.inbox]);
    } catch (e) {
      if (!isAuto) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to read SMS: $e")),
        );
      }
      return;
    }

    if (messages.isEmpty) {
      if (!isAuto) {
        openPopup(
          context,
          title: "No SMS Found",
          description: "No SMS messages could be read from your device inbox.",
          icon: Icons.sms_failed_rounded,
          onCancel: () => popRoute(context),
          onCancelLabel: "Ok",
        );
      }
      return;
    }

    // Get high-water mark timestamp
    int? lastProcessedSmsTime = appStateSettings["lastProcessedSmsTime"];
    if (isAuto && lastProcessedSmsTime == null) {
      int newestMs = DateTime.now().millisecondsSinceEpoch;
      if (messages.isNotEmpty) {
        newestMs = messages
            .map((m) => m.date?.millisecondsSinceEpoch ?? 0)
            .reduce((a, b) => a > b ? a : b);
      }
      await updateSettings("lastProcessedSmsTime", newestMs, updateGlobalState: false);
      return;
    }

    final keywords = [
      "spent",
      "charged",
      "debited",
      "credited",
      "transaction",
      "paid",
      "received",
      "payment",
      "sent to",
      "withdrawn",
      "purchase",
      "amount",
      "transfer",
      "ref:",
      "rs.",
      "inr",
      "usd",
      "eur",
      "gbp",
      "vnd",
      "vnd.",
      "vnd ",
      "otp",
      "a/c",
      "acct",
      "account"
    ];
    messages.sort((a, b) =>
        (b.date ?? DateTime.now()).compareTo(a.date ?? DateTime.now()));

    List<SmsMessage> transactionMessages = [];
    int newestTimestamp = lastProcessedSmsTime ?? 0;

    for (var msg in messages) {
      final msgTime = msg.date?.millisecondsSinceEpoch ?? 0;
      if (isAuto && msgTime <= (lastProcessedSmsTime ?? 0)) {
        continue;
      }

      final body = msg.body?.toLowerCase() ?? "";
      if (keywords.any((kw) => body.contains(kw))) {
        transactionMessages.add(msg);
        if (msgTime > newestTimestamp) {
          newestTimestamp = msgTime;
        }
        if (transactionMessages.length >= 30) {
          break;
        }
      }
    }

    if (transactionMessages.isEmpty) {
      if (!isAuto) {
        openPopup(
          context,
          title: "No Transaction SMS",
          description:
              "No transaction-related SMS messages were found in your inbox.",
          icon: Icons.sms_rounded,
          onCancel: () => popRoute(context),
          onCancelLabel: "Ok",
        );
      }
      return;
    }

    final bool apiEnabled = appStateSettings["aiApiEnabled"] == true;
    final String apiUrl = appStateSettings["aiApiUrl"] ?? "";
    final String apiKey = appStateSettings["aiApiKey"] ?? "";
    final String apiModel = appStateSettings["aiApiModel"] ?? "";

    if (!apiEnabled || apiKey.isEmpty || apiUrl.isEmpty || apiModel.isEmpty) {
      if (!isAuto) {
        openPopup(
          context,
          title: "API Settings Incomplete",
          description:
              "Please enable Cloud AI API and configure the Base URL, API Key, and Model name in settings.",
          icon: Icons.warning_amber_rounded,
          onCancel: () => popRoute(context),
          onCancelLabel: "Ok",
        );
      }
      return;
    }

    final client = OpenAIClient(
      config: OpenAIConfig(
        authProvider: ApiKeyProvider(apiKey),
        baseUrl: apiUrl,
      ),
    );

    final StreamController<int> progressController =
        StreamController<int>.broadcast();
    bool cancelled = false;
    List<SmsTransaction> extractedTransactions = [];

    // Load default wallet and category
    List<TransactionWallet> wallets = await database.getAllWallets();
    String selectedWalletPk = appStateSettings["selectedWalletPk"] ?? "0";
    TransactionWallet? initialWallet;
    for (var w in wallets) {
      if (w.walletPk == selectedWalletPk) {
        initialWallet = w;
        break;
      }
    }
    if (initialWallet == null && wallets.isNotEmpty) {
      initialWallet = wallets.first;
    }
    List<TransactionCategory> categories = await database.getAllCategories();
    TransactionCategory? defaultExpenseCategory;
    TransactionCategory? defaultIncomeCategory;
    for (var cat in categories) {
      if (cat.income == false && defaultExpenseCategory == null) {
        defaultExpenseCategory = cat;
      } else if (cat.income == true && defaultIncomeCategory == null) {
        defaultIncomeCategory = cat;
      }
    }

    openPopupCustom(
      context,
      title: "Extracting Transactions",
      barrierDismissible: false,
      child: SmsScanningDialogContent(
        total: transactionMessages.length,
        progressStream: progressController.stream,
        onCancel: () {
          cancelled = true;
          client.close();
          popRoute(context);
        },
      ),
    );

    final String currentIsoString = DateTime.now().toIso8601String();
    String systemPrompt = appStateSettings["aiSystemPrompt"] ?? "";
    if (systemPrompt.isEmpty) {
      systemPrompt = defaultSystemPrompt;
    }
    systemPrompt = systemPrompt.replaceAll("{current_reference_time}", currentIsoString);

    try {
      for (int i = 0; i < transactionMessages.length; i++) {
        if (cancelled) break;
        progressController.add(i + 1);

        final msg = transactionMessages[i];
        final smsBody = msg.body ?? "";

        try {
          final double aiTemperature = double.tryParse(appStateSettings["aiTemperature"]?.toString() ?? "") ?? 0.0;
          if (appStateSettings["aiVerboseLogging"] == true) {
            print("DEBUG: Sending request with system prompt:\n$systemPrompt");
            print("DEBUG: User message: '$smsBody'");
            print("DEBUG: Using temperature: $aiTemperature");
          }

          final response = await client.chat.completions.create(
            ChatCompletionCreateRequest(
              model: apiModel,
              messages: [
                ChatMessage.system(systemPrompt),
                ChatMessage.user('SMS: "$smsBody"'),
              ],
              temperature: aiTemperature,
            ),
          );

          if (appStateSettings["aiVerboseLogging"] == true) {
            print("DEBUG: API Response: $response");
            print("DEBUG: API Response text getter: '${response.text}'");
            print(
                "DEBUG: API Response message content: '${response.choices.first.message.content}'");
          }

          String content = response.choices.first.message.content ?? "";
          if (content.startsWith("```")) {
            final lines = content.split("\n");
            if (lines.first.startsWith("```")) {
              lines.removeAt(0);
            }
            if (lines.isNotEmpty && lines.last.startsWith("```")) {
              lines.removeLast();
            }
            content = lines.join("\n").trim();
          }

          final data = json.decode(content);
          if (data != null &&
              data is Map &&
              data.isNotEmpty &&
              data["amount"] != null) {
            final double? amt = double.tryParse(data["amount"].toString());
            if (amt != null && amt > 0) {
              DateTime? customDate;
              if (data["timestamp"] != null) {
                customDate = DateTime.tryParse(data["timestamp"].toString());
              }
              TransactionWallet? matchingWallet;
              final String? extCurrency = data["currency"]?.toString().toLowerCase();
              if (extCurrency != null) {
                for (var w in wallets) {
                  if (w.currency?.toLowerCase() == extCurrency) {
                    matchingWallet = w;
                    break;
                  }
                }
              }
              matchingWallet ??= initialWallet;

              extractedTransactions.add(SmsTransaction(
                smsMessage: msg,
                merchant: data["merchant"]?.toString() ?? "Unknown Merchant",
                amount: amt,
                currency: data["currency"]?.toString() ?? "USD",
                type: data["type"]?.toString() == "credit" ? "credit" : "debit",
                selectedWallet: matchingWallet,
                selectedCategory: data["type"]?.toString() == "credit"
                    ? defaultIncomeCategory
                    : defaultExpenseCategory,
                note: data["note"]?.toString() ?? smsBody,
                customDate: customDate,
              ));
            }
          }
        } catch (e) {
          print("Error processing SMS index $i: $e");
        }
      }
    } finally {
      progressController.close();
      client.close();
      if (!cancelled) {
        popRoute(context); // close loader popup
      }
    }

    if (cancelled) return;

    if (extractedTransactions.isEmpty) {
      if (isAuto) {
        await updateSettings("lastProcessedSmsTime", newestTimestamp, updateGlobalState: false);
      } else {
        openPopup(
          context,
          title: "No Transactions Extracted",
          description:
              "The AI did not extract any transactions from your recent SMS notifications.",
          icon: Icons.info_outline,
          onCancel: () => popRoute(context),
          onCancelLabel: "Ok",
        );
      }
      return;
    }

    if (isAuto) {
      await updateSettings("lastProcessedSmsTime", newestTimestamp, updateGlobalState: false);
    }

    showSmsImportDialog(context, extractedTransactions);
  }

  static void showSmsImportDialog(BuildContext context, List<SmsTransaction> list) async {
    final allWallets = Provider.of<AllWallets>(context, listen: false);

    await openBottomSheet(
      context,
      PopupFramework(
        title: "Import SMS Transactions",
        child: StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.6,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final item = list[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            vertical: 8.0, horizontal: 4.0),
                        color:
                            Theme.of(context).colorScheme.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Checkbox(
                                    value: item.import,
                                    onChanged: (val) {
                                      setDialogState(() {
                                        item.import = val ?? true;
                                      });
                                    },
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        TextFont(
                                          text: item.merchant,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        const SizedBox(height: 2),
                                        TextFont(
                                          text: DateFormat.yMMMd()
                                              .add_jm()
                                              .format(item.customDate ?? item.smsMessage.date ?? DateTime.now()),
                                          fontSize: 12,
                                          textColor: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ],
                                    ),
                                  ),
                                  TextFont(
                                    text: convertToMoney(
                                      allWallets,
                                      item.amount *
                                          (item.type == "credit" ? 1.0 : -1.0),
                                      currencyKey: item.selectedWallet?.currency,
                                    ),
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    textColor: item.type == "credit"
                                        ? getColor(context, "incomeAmount")
                                        : getColor(context, "expenseAmount"),
                                  ),
                                ],
                              ),
                              if (item.note.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12.0),
                                  child: Text(
                                    item.note,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontStyle: FontStyle.italic,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  // Category Selector Chip
                                  Expanded(
                                    child: Tappable(
                                      onTap: () async {
                                        MainAndSubcategory result =
                                            await selectCategorySequence(
                                          context,
                                          selectedCategory:
                                              item.selectedCategory,
                                          setSelectedCategory: (cat) {},
                                          selectedSubCategory:
                                              item.selectedSubCategory,
                                          setSelectedSubCategory: (sub) {},
                                          selectedIncomeInitial:
                                              item.type == "credit",
                                        );
                                        if (result.main != null) {
                                          setDialogState(() {
                                            item.selectedCategory = result.main;
                                            item.selectedSubCategory =
                                                result.sub;
                                          });
                                        }
                                      },
                                      color: Theme.of(context)
                                          .colorScheme
                                          .secondaryContainer,
                                      borderRadius: 10,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 8, horizontal: 10),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            if (item.selectedCategory !=
                                                null) ...[
                                              CategoryIcon(
                                                categoryPk: item
                                                    .selectedCategory!
                                                    .categoryPk,
                                                size: 20,
                                              ),
                                              const SizedBox(width: 6),
                                            ],
                                            Flexible(
                                              child: TextFont(
                                                text: item.selectedSubCategory
                                                        ?.name ??
                                                    item.selectedCategory
                                                        ?.name ??
                                                    "Uncategorized",
                                                fontSize: 13,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Wallet Selector Chip
                                  Expanded(
                                    child: Tappable(
                                      onTap: () async {
                                        TransactionWallet? result =
                                            await selectWalletPopup(
                                          context,
                                          selectedWallet: item.selectedWallet,
                                          allowEditWallet: false,
                                        );
                                        if (result != null) {
                                          setDialogState(() {
                                            item.selectedWallet = result;
                                          });
                                        }
                                      },
                                      color: Theme.of(context)
                                          .colorScheme
                                          .secondaryContainer,
                                      borderRadius: 10,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 8, horizontal: 10),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons
                                                  .account_balance_wallet_outlined,
                                              size: 18,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSecondaryContainer,
                                            ),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: TextFont(
                                                text:
                                                    item.selectedWallet?.name ??
                                                        "Select Wallet",
                                                fontSize: 13,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Button(
                        label: "Import Selected",
                        onTap: () async {
                          popRoute(dialogContext); // close sheet
                          openLoadingPopup(context); // show loading spinner
                          try {
                            for (var item in list) {
                              if (!item.import) continue;

                              final finalAmount = item.amount.abs() *
                                  (item.type == "credit" ? 1.0 : -1.0);
                              final transaction = Transaction(
                                transactionPk: "-1",
                                name: item.merchant,
                                amount: finalAmount,
                                note: item.note,
                                categoryFk:
                                    item.selectedCategory?.categoryPk ?? "1",
                                subCategoryFk:
                                    item.selectedSubCategory?.categoryPk,
                                walletFk: item.selectedWallet?.walletPk ?? "0",
                                dateCreated:
                                    item.customDate ?? item.smsMessage.date ?? DateTime.now(),
                                dateTimeModified: null,
                                income: item.type == "credit",
                                paid: true,
                                skipPaid: false,
                              );

                              await database.createOrUpdateTransaction(
                                transaction,
                                insert: true,
                              );
                            }
                            popRoute(context); // close spinner
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      "SMS Transactions imported successfully!")),
                            );
                          } catch (e) {
                            popRoute(context); // close spinner
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      "Failed to import transactions: $e")),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void scrollToTop() {
    pageState.currentState?.scrollToTop();
  }

  @override
  void initState() {
    super.initState();
    _checkPermissionAndSync();
    _checkModelStatus();
  }

  @override
  void dispose() {
    _activeRequest?.abort();
    super.dispose();
  }

  Future<void> _checkPermissionAndSync() async {
    if (getPlatform() == PlatformOS.isAndroid &&
        appStateSettings["readSmsPermission"] == true) {
      PermissionStatus status = await Permission.sms.status;
      if (!status.isGranted) {
        await updateSettings("readSmsPermission", false,
            updateGlobalState: false);
        if (mounted) setState(() {});
      }
    }
  }

  Future<File> _getLocalModelFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/qwen2.5-0.5b-instruct-q4_k_m.gguf');
  }

  Future<void> _checkModelStatus() async {
    final file = await _getLocalModelFile();
    final exists = await file.exists();
    if (exists != (appStateSettings["localAiModelDownloaded"] == true)) {
      await updateSettings("localAiModelDownloaded", exists,
          updateGlobalState: false);
      if (mounted) setState(() {});
    }
  }

  void _cancelDownload() {
    if (_activeRequest != null) {
      _activeRequest!.abort();
    }
  }

  void _startDownload() async {
    if (_isDownloading) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadProgressText = "Starting download...";
    });

    try {
      const url =
          'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf';
      final file = await _getLocalModelFile();

      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }

      if (await file.exists()) {
        await file.delete();
      }

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);

      final request = await client.getUrl(Uri.parse(url));
      _activeRequest = request;

      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception("Server returned status code ${response.statusCode}");
      }

      final contentLength = response.contentLength;
      int bytesDownloaded = 0;

      final fileSink = file.openWrite();

      await for (final chunk in response) {
        fileSink.add(chunk);
        bytesDownloaded += chunk.length;

        if (mounted) {
          setState(() {
            if (contentLength > 0) {
              _downloadProgress = bytesDownloaded / contentLength;
              final currentMb =
                  (bytesDownloaded / (1024 * 1024)).toStringAsFixed(1);
              final totalMb =
                  (contentLength / (1024 * 1024)).toStringAsFixed(1);
              _downloadProgressText =
                  "Downloading: $currentMb MB / $totalMb MB (${(_downloadProgress * 100).toStringAsFixed(1)}%)";
            } else {
              final currentMb =
                  (bytesDownloaded / (1024 * 1024)).toStringAsFixed(1);
              _downloadProgressText =
                  "Downloading: $currentMb MB (size unknown)";
            }
          });
        }
      }

      await fileSink.flush();
      await fileSink.close();

      if (mounted) {
        await updateSettings("localAiModelDownloaded", true,
            updateGlobalState: false);
        setState(() {
          _isDownloading = false;
          _downloadProgress = 0.0;
          _downloadProgressText = "";
        });
      }
    } catch (e) {
      try {
        final file = await _getLocalModelFile();
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadProgress = 0.0;
          _downloadProgressText = "";
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Download failed: $e")),
        );
      }
    } finally {
      _activeRequest = null;
    }
  }

  Future<void> _deleteModel() async {
    try {
      final file = await _getLocalModelFile();
      if (await file.exists()) {
        await file.delete();
      }
      await updateSettings("localAiModelDownloaded", false,
          updateGlobalState: false);
      await updateSettings("runLocally", false, updateGlobalState: false);
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to delete model file: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      key: pageState,
      title: "AI & Automation",
      horizontalPaddingConstrained: true,
      listWidgets: [
        SettingsHeader(title: "SMS Permissions"),
        SettingsContainerSwitch(
          title: "Read SMS Permission",
          description:
              "Allows the app to read transaction notification SMS if enabled",
          onSwitched: (value) async {
            if (value == true) {
              if (getPlatform() == PlatformOS.isAndroid) {
                PermissionStatus status = await Permission.sms.status;
                if (!status.isGranted) {
                  status = await Permission.sms.request();
                }
                if (status.isGranted) {
                  await updateSettings("readSmsPermission", true,
                      updateGlobalState: false);
                  return true;
                } else {
                  return false;
                }
              } else {
                // Not supported on non-Android platforms
                return false;
              }
            } else {
              await updateSettings("readSmsPermission", false,
                  updateGlobalState: false);
              return true;
            }
          },
          initialValue: appStateSettings["readSmsPermission"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.sms_outlined
              : Icons.sms_rounded,
        ),
        if (appStateSettings["readSmsPermission"] == true &&
            getPlatform() == PlatformOS.isAndroid) ...[
          SettingsContainerSwitch(
            title: "Automatic SMS Sync",
            description:
                "Automatically check and process new transaction SMS when app resumes",
            onSwitched: (value) async {
              if (value == true) {
                if (appStateSettings["lastProcessedSmsTime"] == null) {
                  try {
                    final SmsQuery query = SmsQuery();
                    List<SmsMessage> messages = await query.querySms(kinds: [SmsQueryKind.inbox]);
                    int newestMs = DateTime.now().millisecondsSinceEpoch;
                    if (messages.isNotEmpty) {
                      newestMs = messages
                          .map((m) => m.date?.millisecondsSinceEpoch ?? 0)
                          .reduce((a, b) => a > b ? a : b);
                    }
                    await updateSettings("lastProcessedSmsTime", newestMs, updateGlobalState: false);
                  } catch (e) {
                    print("Error setting initial lastProcessedSmsTime: $e");
                    await updateSettings("lastProcessedSmsTime", DateTime.now().millisecondsSinceEpoch, updateGlobalState: false);
                  }
                }
              }
              await updateSettings("autoSmsSync", value,
                  updateGlobalState: false);
              setState(() {});
              return true;
            },
            initialValue: appStateSettings["autoSmsSync"] == true,
            icon: appStateSettings["outlinedIcons"]
                ? Icons.sync_outlined
                : Icons.sync_rounded,
          ),
        ],
        if (getPlatform() == PlatformOS.isAndroid) ...[
          SettingsContainer(
            title: "Process All SMS",
            icon: appStateSettings["outlinedIcons"]
                ? Icons.document_scanner_outlined
                : Icons.document_scanner_rounded,
            description:
                "Read SMS inbox and extract transaction details via AI",
            onTap: () {
              _processAllSms();
            },
          ),
        ],
        SettingsHeader(title: "Local AI Settings"),
        SettingsContainerDropdown(
          title: "Local AI Model",
          icon: appStateSettings["outlinedIcons"]
              ? Icons.psychology_outlined
              : Icons.psychology_rounded,
          initial: appStateSettings["localAiModel"] ?? "qwen3.5 0.8b",
          items: const ["qwen3.5 0.8b"],
          onChanged: (value) async {
            await updateSettings("localAiModel", value,
                updateGlobalState: false);
            setState(() {});
          },
        ),
        if (appStateSettings["localAiModelDownloaded"] != true) ...[
          if (_isDownloading)
            SettingsContainer(
              title: "Downloading Model...",
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.downloading_outlined
                  : Icons.downloading_rounded,
              description: _downloadProgressText,
              afterWidget: TextButton(
                onPressed: _cancelDownload,
                child: const Text("Cancel"),
              ),
              descriptionWidget: Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _downloadProgress,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "${(_downloadProgress * 100).toInt()}%",
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            SettingsContainer(
              title: "Download qwen3.5 0.8b",
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.download_outlined
                  : Icons.download_rounded,
              description: "Required to run local AI inference. Size: ~397 MB.",
              afterWidget: TextButton(
                onPressed: _startDownload,
                child: const Text("Download"),
              ),
              onTap: _startDownload,
            ),
        ] else ...[
          SettingsContainer(
            title: "Model Status",
            icon: appStateSettings["outlinedIcons"]
                ? Icons.check_circle_outlined
                : Icons.check_circle_rounded,
            description: "qwen3.5 0.8b is downloaded & ready.",
            afterWidget: TextButton(
              onPressed: _deleteModel,
              child: Text(
                "Delete",
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        ],
        SettingsContainerSwitch(
          title: "Run Locally",
          description: "Process and run transaction analysis on-device",
          onSwitched: (value) async {
            if (value == true) {
              if (appStateSettings["localAiModelDownloaded"] == true) {
                await updateSettings("runLocally", true,
                    updateGlobalState: false);
                return true;
              } else {
                openPopup(
                  context,
                  title: "Model Not Downloaded",
                  description:
                      "You need to download the local AI model before enabling local running.",
                  icon: appStateSettings["outlinedIcons"]
                      ? Icons.warning_amber_outlined
                      : Icons.warning_amber_rounded,
                  onCancel: () {
                    popRoute(context);
                  },
                  onCancelLabel: "Ok",
                );
                return false;
              }
            } else {
              await updateSettings("runLocally", false,
                  updateGlobalState: false);
              return true;
            }
          },
          initialValue: appStateSettings["runLocally"] == true &&
              appStateSettings["localAiModelDownloaded"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.lan_outlined
              : Icons.lan_rounded,
        ),
        SettingsHeader(title: "Cloud AI API Settings"),
        SettingsContainerSwitch(
          title: "Use Cloud AI API",
          description:
              "Enable transaction analysis via external OpenAI-compatible API",
          onSwitched: (value) async {
            await updateSettings("aiApiEnabled", value,
                updateGlobalState: false);
            setState(() {});
            return true;
          },
          initialValue: appStateSettings["aiApiEnabled"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.cloud_outlined
              : Icons.cloud_rounded,
        ),
        if (appStateSettings["aiApiEnabled"] == true) ...[
          SettingsContainer(
            title: "API Base URL",
            description:
                appStateSettings["aiApiUrl"] ?? "https://api.openai.com/v1",
            icon: appStateSettings["outlinedIcons"]
                ? Icons.link_outlined
                : Icons.link_rounded,
            onTap: () {
              _enterTextSettingBottomSheet(
                context: context,
                title: "API Base URL",
                settingKey: "aiApiUrl",
                icon: appStateSettings["outlinedIcons"]
                    ? Icons.link_outlined
                    : Icons.link_rounded,
                placeholder: "https://api.openai.com/v1",
              );
            },
          ),
          SettingsContainer(
            title: "API Key",
            description: (appStateSettings["aiApiKey"] ?? "").isEmpty
                ? "Not Set"
                : "••••••••",
            icon: appStateSettings["outlinedIcons"]
                ? Icons.vpn_key_outlined
                : Icons.vpn_key_rounded,
            onTap: () {
              _enterTextSettingBottomSheet(
                context: context,
                title: "API Key",
                settingKey: "aiApiKey",
                icon: appStateSettings["outlinedIcons"]
                    ? Icons.vpn_key_outlined
                    : Icons.vpn_key_rounded,
                placeholder: "Enter API Key",
              );
            },
          ),
          SettingsContainer(
            title: "Model Name",
            description: appStateSettings["aiApiModel"] ?? "gpt-4o-mini",
            icon: appStateSettings["outlinedIcons"]
                ? Icons.model_training_outlined
                : Icons.model_training_rounded,
            onTap: () {
              _enterTextSettingBottomSheet(
                context: context,
                title: "Model Name",
                settingKey: "aiApiModel",
                icon: appStateSettings["outlinedIcons"]
                    ? Icons.model_training_outlined
                    : Icons.model_training_rounded,
                placeholder: "gpt-4o-mini",
              );
            },
          ),
        ],
        SettingsHeader(title: "AI Developer Settings"),
        SettingsContainerSwitch(
          title: "Enable Developer Options",
          description: "Show advanced fine-tuning settings for the AI model",
          onSwitched: (value) async {
            await updateSettings("aiDevSettingsEnabled", value, updateGlobalState: false);
            setState(() {});
            return true;
          },
          initialValue: appStateSettings["aiDevSettingsEnabled"] == true,
          icon: appStateSettings["outlinedIcons"]
              ? Icons.developer_mode_outlined
              : Icons.developer_mode_rounded,
        ),
        if (appStateSettings["aiDevSettingsEnabled"] == true) ...[
          SettingsContainer(
            title: "System Prompt",
            description: "Customize the instructions passed to the AI model",
            icon: appStateSettings["outlinedIcons"]
                ? Icons.description_outlined
                : Icons.description_rounded,
            onTap: () {
              _enterSystemPromptBottomSheet(
                context: context,
                title: "Edit System Prompt",
                settingKey: "aiSystemPrompt",
                defaultPrompt: defaultSystemPrompt,
              );
            },
          ),
          SettingsContainerDropdown(
            title: "Model Temperature",
            description: "Controls randomness: 0.0 is deterministic, 1.0 is creative",
            icon: appStateSettings["outlinedIcons"]
                ? Icons.thermostat_outlined
                : Icons.thermostat_rounded,
            initial: appStateSettings["aiTemperature"]?.toString() ?? "0.0",
            items: const ["0.0", "0.1", "0.2", "0.3", "0.5", "0.7", "1.0"],
            onChanged: (value) async {
              await updateSettings("aiTemperature", value, updateGlobalState: false);
              setState(() {});
            },
          ),
          SettingsContainerSwitch(
            title: "Verbose API Logging",
            description: "Print detailed JSON payloads and responses to console",
            onSwitched: (value) async {
              await updateSettings("aiVerboseLogging", value, updateGlobalState: false);
              setState(() {});
              return true;
            },
            initialValue: appStateSettings["aiVerboseLogging"] == true,
            icon: appStateSettings["outlinedIcons"]
                ? Icons.terminal_outlined
                : Icons.terminal_rounded,
          ),
        ],
      ],
    );
  }
}

class SmsTransaction {
  final SmsMessage smsMessage;
  String merchant;
  double amount;
  String currency;
  String type; // "credit" or "debit"
  TransactionCategory? selectedCategory;
  TransactionCategory? selectedSubCategory;
  TransactionWallet? selectedWallet;
  bool import;
  String note;
  DateTime? customDate;

  SmsTransaction({
    required this.smsMessage,
    required this.merchant,
    required this.amount,
    required this.currency,
    required this.type,
    required this.selectedWallet,
    required this.selectedCategory,
    this.selectedSubCategory,
    this.import = true,
    required this.note,
    this.customDate,
  });
}

class SmsScanningDialogContent extends StatefulWidget {
  final int total;
  final Stream<int> progressStream;
  final VoidCallback onCancel;

  const SmsScanningDialogContent({
    super.key,
    required this.total,
    required this.progressStream,
    required this.onCancel,
  });

  @override
  State<SmsScanningDialogContent> createState() =>
      _SmsScanningDialogContentState();
}

class _SmsScanningDialogContentState extends State<SmsScanningDialogContent> {
  int _current = 0;
  StreamSubscription<int>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.progressStream.listen((current) {
      if (mounted) {
        setState(() {
          _current = current;
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double percent = widget.total > 0 ? _current / widget.total : 0.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: percent,
            minHeight: 12,
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 15),
        TextFont(
          text: "Processing SMS $_current of ${widget.total}...",
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
        const SizedBox(height: 25),
        Button(
          label: "Cancel",
          color: Theme.of(context).colorScheme.errorContainer,
          textColor: Theme.of(context).colorScheme.onErrorContainer,
          onTap: widget.onCancel,
        ),
      ],
    );
  }
}
