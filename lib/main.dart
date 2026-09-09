import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RestaurantSplitterScreen(),
    ));

String capitalize(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  return trimmed[0].toUpperCase() + trimmed.substring(1);
}

String toDativeName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return name;
  final lower = trimmed.toLowerCase();

  if (RegExp(r'[бвгджзклмнпрстфхцчшщ]$').hasMatch(lower)) {
    return '$trimmedу';
  }
  if (lower.endsWith('ь') || lower.endsWith('й')) {
    return '${trimmed.substring(0, trimmed.length - 1)}ю';
  }
  if (lower.endsWith('а') || lower.endsWith('я')) {
    return '${trimmed.substring(0, trimmed.length - 1)}е';
  }
  return trimmed;
}

class BillItem {
  String id;
  String title;
  double price;
  final Set<String> consumedBy;

  BillItem({
    required this.id,
    required this.title,
    required this.price,
    Set<String>? consumedBy,
  }) : consumedBy = consumedBy ?? {};
}

class RestaurantSplitterScreen extends StatefulWidget {
  const RestaurantSplitterScreen({super.key});

  @override
  State<RestaurantSplitterScreen> createState() => _RestaurantSplitterScreenState();
}

class _RestaurantSplitterScreenState extends State<RestaurantSplitterScreen> {
  final List<String> _members = [];
  final Map<String, double> _paidAmounts = {};
  String? _activeMember;

  bool _singlePayerMode = true;
  String? _singlePayerName;

  final List<BillItem> _items = [];
  bool _isProcessing = false;
  String _processingStatus = 'Обработка...';
  final ImagePicker _picker = ImagePicker();

  final _newMemberController = TextEditingController();
  final _manualItemNameController = TextEditingController();
  final _manualItemPriceController = TextEditingController();

  bool _includeTips = false;
  bool _isTipInPercent = true;
  final _tipInputController = TextEditingController(text: '10');

  void _confirmClearAllItems() {
    if (_items.isEmpty) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить весь чек?'),
        content: const Text('Все добавленные блюда и отметки будут удалены. Список участников останется.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              setState(() => _items.clear());
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Чек полностью очищен')),
              );
            },
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
  }

  bool _isServiceLine(String text) {
    final lower = text.toLowerCase();
    final stopWords = [
      'инн', 'ккт', 'фн', 'фд', 'фп', 'кассир', 'смена', 'чек', 'итог',
      'итого', 'оплата', 'нал', 'безнал', 'спасибо', 'сайт', 'тел', 'дата', 'время',
      'касса', 'ндс', 'терминал', 'номер', 'добро', 'скидка', 'наличными',
      'электронными', 'получено', 'сдача', 'приход', 'расход', 'подпись',
      'покупатель', 'продажа', 'место расчетов', 'рнк', 'заводской', 'код'
    ];
    for (var w in stopWords) {
      if (lower.contains(w)) return true;
    }
    return false;
  }

  List<BillItem> _extractItemsFromLines(List<String> rawLines) {
    final List<BillItem> parsed = [];
    final priceRegex = RegExp(r'(\d+[.,]\d{2})|(\b\d{2,5}\b)');
    String pendingTitle = '';

    for (var raw in rawLines) {
      var line = raw.trim();
      if (line.isEmpty || _isServiceLine(line)) continue;

      if (RegExp(r'^\s*([0-9.,]+)\s*(\*|x|х)\s*([0-9.,]+)').hasMatch(line)) {
        continue;
      }

      final matches = priceRegex.allMatches(line).toList();
      if (matches.isNotEmpty) {
        final lastMatch = matches.last;
        final priceStr = lastMatch.group(0)!.replaceAll(',', '.');
        final priceVal = double.tryParse(priceStr);

        var titlePart = line.substring(0, lastMatch.start).replaceAll(RegExp(r'[-=:#*.]+'), ' ').trim();
        if (titlePart.isEmpty && pendingTitle.isNotEmpty) {
          titlePart = pendingTitle;
          pendingTitle = '';
        }

        if (priceVal != null && priceVal >= 15 && priceVal < 250000) {
          if (titlePart.length < 2) titlePart = 'Позиция';
          parsed.add(BillItem(
            id: UniqueKey().toString(),
            title: capitalize(titlePart),
            price: priceVal,
          ));
        }
      } else {
        if (!RegExp(r'^\d+$').hasMatch(line) && line.length > 2) {
          pendingTitle = line;
        }
      }
    }
    return parsed;
  }

  void _showParsedReviewDialog(List<BillItem> candidateItems) {
    if (candidateItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось найти позиции с ценами. Сделайте фото ровнее или используйте QR / голосовой ввод.'),
        ),
      );
      return;
    }

    final localList = List<BillItem>.from(candidateItems);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Проверьте чек (${localList.length} поз.)', style: const TextStyle(fontSize: 18)),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: localList.isEmpty
                ? const Center(child: Text('Все позиции удалены'))
                : ListView.builder(
                    itemCount: localList.length,
                    itemBuilder: (context, index) {
                      final item = localList[index];
                      return Card(
                        key: ValueKey(item.id),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: TextFormField(
                                  key: ValueKey('title_${item.id}'),
                                  initialValue: item.title,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    hintText: 'Название',
                                  ),
                                  onChanged: (val) => item.title = val,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  key: ValueKey('price_${item.id}'),
                                  initialValue: item.price.toStringAsFixed(0),
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    suffixText: '₽',
                                    border: InputBorder.none,
                                    hintText: '0',
                                  ),
                                  onChanged: (val) {
                                    item.price = double.tryParse(val.replaceAll(',', '.')) ?? item.price;
                                  },
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.red, size: 20),
                                onPressed: () {
                                  setDialogState(() {
                                    localList.removeAt(index);
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                setState(() => _items.addAll(localList));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Добавлено позиций в счёт: ${localList.length}')),
                );
              },
              child: Text('Добавить в счёт (${localList.length})'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanReceiptPhotoAuto(ImageSource source) async {
    final XFile? file = await _picker.pickImage(
      source: source,
      maxWidth: 2048,
      imageQuality: 95,
    );
    if (file == null) return;

    setState(() {
      _isProcessing = true;
      _processingStatus = 'Распознавание кириллицы (Tesseract)...';
    });

    try {
      // В tesseract_ocr 0.5.0 язык передается позиционным аргументом
      final String extractedText = await TesseractOcr.extractText(file.path);

      final lines = extractedText.split(RegExp(r'[\n\r]+'));
      final foundItems = _extractItemsFromLines(lines);

      if (mounted) {
        _showParsedReviewDialog(foundItems);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка распознавания: $e'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showVoiceOrBatchInputDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Голосовой или текстовый ввод'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Нажмите микрофон на клавиатуре смартфона и надиктуйте:\n«Шашлык 650, Цезарь 420, Морс 150»',
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: textController,
              autofocus: true,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Цезарь 420, Шашлык 650...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
            onPressed: () {
              final text = textController.text;
              Navigator.pop(ctx);
              final lines = text.split(RegExp(r'[\n\r,;]+'));
              final items = _extractItemsFromLines(lines);
              if (items.isNotEmpty) {
                _showParsedReviewDialog(items);
              }
            },
            child: const Text('Разобрать'),
          ),
        ],
      ),
    );
  }

  void _openQrScanner() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: const Text('Наведите камеру на QR чека')),
          body: MobileScanner(
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                final val = barcode.rawValue;
                if (val != null && val.contains('s=')) {
                  Navigator.pop(ctx);
                  _handleQrReceiptData(val);
                  return;
                }
              }
            },
          ),
        ),
      ),
    );
  }

  void _handleQrReceiptData(String qrRaw) {
    final match = RegExp(r's=([0-9.]+)').firstMatch(qrRaw);
    if (match != null) {
      final total = double.tryParse(match.group(1)!);
      if (total != null) {
        setState(() {
          _items.add(BillItem(id: UniqueKey().toString(), title: 'Счет по QR-коду', price: total));
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Сумма чека ${total.toStringAsFixed(2)} ₽ добавлена!')),
        );
      }
    }
  }

  void _addManualItem() {
    final title = capitalize(_manualItemNameController.text.trim());
    final price = double.tryParse(_manualItemPriceController.text.replaceAll(',', '.'));

    if (title.isEmpty || price == null || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Укажите название и цену')));
      return;
    }

    setState(() {
      _items.add(BillItem(id: UniqueKey().toString(), title: title, price: price));
      _manualItemNameController.clear();
      _manualItemPriceController.clear();
    });
  }

  void _addMember() {
    final name = capitalize(_newMemberController.text.trim());
    if (name.isNotEmpty && !_members.contains(name)) {
      setState(() {
        _members.add(name);
        _paidAmounts[name] = 0.0;
        _activeMember ??= name;
        _singlePayerName ??= name;
        _newMemberController.clear();
      });
    }
  }

  Map<String, double> _calculateBaseTotals() {
    Map<String, double> totals = {for (var m in _members) m: 0.0};
    for (var item in _items) {
      if (item.consumedBy.isNotEmpty) {
        double splitPrice = item.price / item.consumedBy.length;
        for (var person in item.consumedBy) {
          totals[person] = (totals[person] ?? 0.0) + splitPrice;
        }
      }
    }
    return totals;
  }

  double _calculateTotalTip(double baseSum) {
    if (!_includeTips || baseSum <= 0) return 0.0;
    final val = double.tryParse(_tipInputController.text.replaceAll(',', '.')) ?? 0.0;
    return _isTipInPercent ? baseSum * (val / 100) : val;
  }

  Map<String, double> _calculateFinalTotals(Map<String, double> baseTotals) {
    final baseSum = baseTotals.values.fold(0.0, (sum, val) => sum + val);
    final totalTip = _calculateTotalTip(baseSum);

    Map<String, double> finalTotals = {};
    baseTotals.forEach((member, memberBaseSum) {
      double tipShare = (baseSum > 0 && totalTip > 0) ? (memberBaseSum / baseSum) * totalTip : 0.0;
      finalTotals[member] = memberBaseSum + tipShare;
    });

    return finalTotals;
  }

  Map<String, double> _getEffectivePaidAmounts(double totalRequired) {
    Map<String, double> eff = {};
    if (_singlePayerMode) {
      for (var m in _members) {
        eff[m] = (m == _singlePayerName) ? totalRequired : 0.0;
      }
    } else {
      for (var m in _members) {
        eff[m] = _paidAmounts[m] ?? 0.0;
      }
    }
    return eff;
  }

  List<String> _calculateTransfers(Map<String, double> finalTotals, Map<String, double> effectivePaid) {
    if (_members.isEmpty) return [];

    Map<String, double> balances = {};
    for (var m in _members) {
      final paid = effectivePaid[m] ?? 0.0;
      final consumed = finalTotals[m] ?? 0.0;
      balances[m] = paid - consumed;
    }

    List<MapEntry<String, double>> debtors = [];
    List<MapEntry<String, double>> creditors = [];

    balances.forEach((person, bal) {
      if (bal < -0.01) debtors.add(MapEntry(person, -bal));
      if (bal > 0.01) creditors.add(MapEntry(person, bal));
    });

    debtors.sort((a, b) => b.value.compareTo(a.value));
    creditors.sort((a, b) => b.value.compareTo(a.value));

    List<String> transfers = [];
    int d = 0, c = 0;

    while (d < debtors.length && c < creditors.length) {
      double pay = debtors[d].value < creditors[c].value ? debtors[d].value : creditors[c].value;
      if (pay > 0.01) {
        transfers.add('👉 ${debtors[d].key} переводит ${toDativeName(creditors[c].key)}: ${pay.toStringAsFixed(2)} ₽');
      }

      debtors[d] = MapEntry(debtors[d].key, debtors[d].value - pay);
      creditors[c] = MapEntry(creditors[c].key, creditors[c].value - pay);

      if (debtors[d].value <= 0.01) d++;
      if (creditors[c].value <= 0.01) c++;
    }

    return transfers;
  }

  void _shareReport(Map<String, double> finalTotals, List<String> transfers, Map<String, double> effectivePaid, double remainingToPay) {
    if (_members.isEmpty || _items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Добавьте участников и позиции чека')));
      return;
    }

    final totalCheck = _items.fold(0.0, (sum, item) => sum + item.price);
    final totalWithTips = finalTotals.values.fold(0.0, (sum, val) => sum + val);
    final totalPaid = effectivePaid.values.fold(0.0, (sum, val) => sum + val);

    final StringBuffer buffer = StringBuffer();
    buffer.writeln('🧾 РАСЧЕТ СЧЕТА');
    buffer.writeln('Сумма по чеку: ${totalCheck.toStringAsFixed(2)} ₽');
    if (_includeTips) {
      buffer.writeln('Итого с чаевыми: ${totalWithTips.toStringAsFixed(2)} ₽');
    }
    buffer.writeln('Всего внесено: ${totalPaid.toStringAsFixed(2)} ₽');

    if (remainingToPay > 0.01) {
      buffer.writeln('⚠️ ОСТАЛОСЬ ДОПЛАТИТЬ: ${remainingToPay.toStringAsFixed(2)} ₽');
    } else {
      buffer.writeln('✅ Счет закрыт полностью');
    }

    final unassigned = _items.where((it) => it.consumedBy.isEmpty).toList();
    if (unassigned.isNotEmpty) {
      buffer.writeln('\n⚠️ НЕ РАСПРЕДЕЛЕННЫЕ ПОЗИЦИИ:');
      for (var it in unassigned) {
        buffer.writeln('• ${it.title}: ${it.price.toStringAsFixed(2)} ₽');
      }
    }

    buffer.writeln('\n💰 ВНЕСЕННЫЕ ОПЛАТЫ:');
    for (var m in _members) {
      final p = effectivePaid[m] ?? 0.0;
      if (p > 0) buffer.writeln('• $m: ${p.toStringAsFixed(2)} ₽');
    }

    buffer.writeln('\n📋 ДЕТАЛИЗАЦИЯ ПО УЧАСТНИКАМ:');
    for (var member in _members) {
      final memberItems = _items.where((it) => it.consumedBy.contains(member)).toList();
      final itemsText = memberItems.isEmpty
          ? 'Ничего не выбрано'
          : memberItems.map((it) {
              if (it.consumedBy.length > 1) {
                return '${it.title} (1/${it.consumedBy.length})';
              }
              return it.title;
            }).join(', ');

      final sum = finalTotals[member] ?? 0.0;
      buffer.writeln('• $member: $itemsText — ${sum.toStringAsFixed(2)} ₽');
    }

    buffer.writeln('\n💳 ИТОГОВЫЕ ПЕРЕВОДЫ:');
    if (transfers.isEmpty) {
      buffer.writeln('Все в расчете.');
    } else {
      for (var t in transfers) {
        buffer.writeln(t);
      }
    }

    Share.share(buffer.toString(), subject: 'Расчет счета');
  }

  @override
  Widget build(BuildContext context) {
    final baseTotals = _calculateBaseTotals();
    final finalTotals = _calculateFinalTotals(baseTotals);
    final totalCheckAmount = _items.fold(0.0, (sum, item) => sum + item.price);
    final totalWithTips = finalTotals.values.fold(0.0, (sum, val) => sum + val);

    final effectivePaid = _getEffectivePaidAmounts(totalWithTips > 0 ? totalWithTips : totalCheckAmount);
    final totalPaid = effectivePaid.values.fold(0.0, (sum, val) => sum + val);
    final remainingToPay = (totalWithTips - totalPaid) > 0.01 ? (totalWithTips - totalPaid) : 0.0;

    final transfers = _calculateTransfers(finalTotals, effectivePaid);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Разбор чека'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Поделиться отчетом',
            onPressed: () => _shareReport(finalTotals, transfers, effectivePaid, remainingToPay),
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Сканировать QR чека',
            onPressed: _openQrScanner,
          ),
        ],
      ),
      body: _isProcessing
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 14),
                  Text(_processingStatus, style: const TextStyle(fontWeight: FontWeight.w500)),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('1. Участники и порядок оплаты:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (_members.isEmpty)
                            const Text('Добавьте участников встречи ниже', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic))
                          else
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: _members.map((m) => Chip(
                                    label: Text(m),
                                    onDeleted: () {
                                      setState(() {
                                        _members.remove(m);
                                        _paidAmounts.remove(m);
                                        for (var it in _items) {
                                          it.consumedBy.remove(m);
                                        }
                                        if (_activeMember == m) _activeMember = _members.isNotEmpty ? _members.first : null;
                                        if (_singlePayerName == m) _singlePayerName = _members.isNotEmpty ? _members.first : null;
                                      });
                                    },
                                  )).toList(),
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _newMemberController,
                                  textCapitalization: TextCapitalization.words,
                                  decoration: const InputDecoration(
                                    hintText: 'Имя участника',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  onSubmitted: (_) => _addMember(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: _addMember,
                                icon: const Icon(Icons.person_add),
                                label: const Text('Добавить'),
                              ),
                            ],
                          ),
                          if (_members.isNotEmpty) ...[
                            const Divider(height: 20),
                            const Text('Кто оплачивает счет?', style: TextStyle(fontWeight: FontWeight.bold)),
                            RadioListTile<bool>(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Один человек закрыл весь чек'),
                              value: true,
                              groupValue: _singlePayerMode,
                              onChanged: (val) => setState(() => _singlePayerMode = val!),
                            ),
                            if (_singlePayerMode)
                              Padding(
                                padding: const EdgeInsets.only(left: 12, bottom: 8),
                                child: Row(
                                  children: [
                                    const Text('Кто платил: ', style: TextStyle(fontWeight: FontWeight.w500)),
                                    DropdownButton<String>(
                                      value: _singlePayerName ?? _members.first,
                                      items: _members.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                                      onChanged: (val) => setState(() => _singlePayerName = val),
                                    ),
                                  ],
                                ),
                              ),
                            RadioListTile<bool>(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Несколько человек / раздельные депозиты'),
                              value: false,
                              groupValue: _singlePayerMode,
                              onChanged: (val) => setState(() => _singlePayerMode = val!),
                            ),
                            if (!_singlePayerMode)
                              ..._members.map((m) => Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Row(
                                      children: [
                                        Expanded(flex: 3, child: Text(m, style: const TextStyle(fontWeight: FontWeight.w600))),
                                        Expanded(
                                          flex: 3,
                                          child: TextFormField(
                                            initialValue: _paidAmounts[m] == 0.0 ? '' : _paidAmounts[m]?.toStringAsFixed(0),
                                            keyboardType: TextInputType.number,
                                            decoration: const InputDecoration(
                                              hintText: '0',
                                              suffixText: '₽',
                                              labelText: 'Внес / Депозит',
                                              isDense: true,
                                              border: OutlineInputBorder(),
                                            ),
                                            onChanged: (val) {
                                              setState(() {
                                                _paidAmounts[m] = double.tryParse(val.replaceAll(',', '.')) ?? 0.0;
                                              });
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  )),
                          ]
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  Card(
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('2. Позиции чека:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              if (_items.isNotEmpty)
                                TextButton.icon(
                                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                                  onPressed: _confirmClearAllItems,
                                  icon: const Icon(Icons.delete_sweep, size: 20),
                                  label: const Text('Очистить весь чек'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                                onPressed: _showVoiceOrBatchInputDialog,
                                icon: const Icon(Icons.mic),
                                label: const Text('Голос / Вставить список'),
                              ),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
                                onPressed: _openQrScanner,
                                icon: const Icon(Icons.qr_code_scanner),
                                label: const Text('QR чека'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _scanReceiptPhotoAuto(ImageSource.camera),
                                icon: const Icon(Icons.camera_alt),
                                label: const Text('Камера'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _scanReceiptPhotoAuto(ImageSource.gallery),
                                icon: const Icon(Icons.photo_library),
                                label: const Text('Галерея'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Divider(),
                          const Text('Или добавить вручную:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: TextField(
                                  controller: _manualItemNameController,
                                  textCapitalization: TextCapitalization.sentences,
                                  decoration: const InputDecoration(labelText: 'Блюдо', isDense: true),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: TextField(
                                  controller: _manualItemPriceController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Цена ₽', isDense: true),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add_circle, color: Colors.indigo, size: 30),
                                onPressed: _addManualItem,
                              )
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  if (_members.isNotEmpty && _items.isNotEmpty) ...[
                    Card(
                      color: Colors.blue.shade50,
                      elevation: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('3. Выберите человека для отметки позиций:', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              children: _members.map((m) {
                                final isSelected = _activeMember == m;
                                return ChoiceChip(
                                  label: Text(m),
                                  selected: isSelected,
                                  selectedColor: Colors.blue.shade200,
                                  onSelected: (val) {
                                    if (val) setState(() => _activeMember = m);
                                  },
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      elevation: 1,
                      child: ExpansionTile(
                        initiallyExpanded: true,
                        leading: const Icon(Icons.restaurant_menu),
                        title: Text('Что заказывал(а) $_activeMember?', style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('Позиций в чеке: ${_items.length}. Отметьте нужное:'),
                        children: _items.map((item) {
                          final isChecked = item.consumedBy.contains(_activeMember);
                          final count = item.consumedBy.length;
                          String subtitle = '${item.price.toStringAsFixed(2)} ₽';

                          if (count == 0) {
                            subtitle += ' ❌ НЕ ВЫБРАНО НИКЕМ!';
                          } else if (count > 1) {
                            subtitle += ' (делится на $count чел. — ${(item.price / count).toStringAsFixed(2)} ₽/чел)';
                          } else if (count == 1 && !isChecked) {
                            subtitle += ' (выбрал: ${item.consumedBy.first})';
                          }

                          return CheckboxListTile(
                            value: isChecked,
                            title: Text(item.title),
                            subtitle: Text(
                              subtitle,
                              style: TextStyle(
                                color: count == 0 ? Colors.red.shade700 : Colors.black54,
                                fontWeight: count == 0 ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            secondary: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.grey),
                              onPressed: () => setState(() => _items.remove(item)),
                            ),
                            onChanged: (val) {
                              setState(() {
                                if (val == true) {
                                  item.consumedBy.add(_activeMember!);
                                } else {
                                  item.consumedBy.remove(_activeMember!);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                    ),
                  ],

                  const SizedBox(height: 10),

                  if (_items.isNotEmpty)
                    Card(
                      elevation: 1,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Чаевые официанту', style: TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: const Text('По желанию. Делятся пропорционально заказам.'),
                              value: _includeTips,
                              onChanged: (val) => setState(() => _includeTips = val),
                            ),
                            if (_includeTips) ...[
                              const Divider(),
                              Row(
                                children: [
                                  ChoiceChip(
                                    label: const Text('В процентах (%)'),
                                    selected: _isTipInPercent,
                                    onSelected: (v) => setState(() => _isTipInPercent = true),
                                  ),
                                  const SizedBox(width: 8),
                                  ChoiceChip(
                                    label: const Text('Сумма (₽)'),
                                    selected: !_isTipInPercent,
                                    onSelected: (v) => setState(() => _isTipInPercent = false),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              if (_isTipInPercent)
                                Row(
                                  children: [
                                    ...[5.0, 10.0, 15.0].map((pct) => Padding(
                                          padding: const EdgeInsets.only(right: 6),
                                          child: ActionChip(
                                            label: Text('${pct.toInt()}%'),
                                            onPressed: () => setState(() => _tipInputController.text = pct.toInt().toString()),
                                          ),
                                        )),
                                    Expanded(
                                      child: TextField(
                                        controller: _tipInputController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(labelText: 'Свой %', isDense: true),
                                        onChanged: (_) => setState(() {}),
                                      ),
                                    ),
                                  ],
                                )
                              else
                                TextField(
                                  controller: _tipInputController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Сумма чаевых (₽)', hintText: '500', isDense: true),
                                  onChanged: (_) => setState(() {}),
                                ),
                            ]
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 16),

                  if (_members.isNotEmpty && _items.isNotEmpty) ...[
                    Builder(
                      builder: (context) {
                        final unassigned = _items.where((it) => it.consumedBy.isEmpty).toList();
                        if (unassigned.isEmpty) return const SizedBox.shrink();
                        final unassignedSum = unassigned.fold(0.0, (s, it) => s + it.price);
                        return Card(
                          color: Colors.amber.shade100,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            side: BorderSide(color: Colors.amber.shade800, width: 1.5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.warning_amber_rounded, color: Colors.amber.shade900),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'НЕ ВЫБРАНО: ${unassigned.length} поз. на ${unassignedSum.toStringAsFixed(2)} ₽',
                                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber.shade900, fontSize: 15),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                const Text('Кто-то забыл отметить свои позиции:', style: TextStyle(fontSize: 12, color: Colors.black87)),
                                const SizedBox(height: 4),
                                ...unassigned.map((it) => Text('• ${it.title} — ${it.price.toStringAsFixed(2)} ₽', style: const TextStyle(fontWeight: FontWeight.w600))),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    const Text('ДЕТАЛЬНЫЙ ОТЧЕТ ПО УЧАСТНИКАМ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    ..._members.map((member) {
                      final memberItems = _items.where((it) => it.consumedBy.contains(member)).toList();
                      final totalSum = finalTotals[member] ?? 0.0;
                      final paid = effectivePaid[member] ?? 0.0;
                      final bal = paid - totalSum;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        elevation: 1,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(member, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.indigo)),
                                  Text(
                                    'Заказ: ${totalSum.toStringAsFixed(2)} ₽',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                ],
                              ),
                              Text(
                                'Внес(ла): ${paid.toStringAsFixed(2)} ₽  |  Баланс: ${bal >= 0 ? "+" : ""}${bal.toStringAsFixed(2)} ₽',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: bal >= 0 ? Colors.green.shade700 : Colors.red.shade700,
                                ),
                              ),
                              const Divider(),
                              if (memberItems.isEmpty)
                                const Text('Ничего не выбрано', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic))
                              else
                                ...memberItems.map((it) {
                                  final isShared = it.consumedBy.length > 1;
                                  final partPrice = it.price / it.consumedBy.length;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text('• ', style: TextStyle(fontWeight: FontWeight.bold)),
                                        Expanded(
                                          child: Text(
                                            isShared ? '${it.title} (делится на ${it.consumedBy.length})' : it.title,
                                            style: const TextStyle(fontSize: 14),
                                          ),
                                        ),
                                        Text('${partPrice.toStringAsFixed(2)} ₽', style: const TextStyle(color: Colors.black87)),
                                      ],
                                    ),
                                  );
                                }),
                            ],
                          ),
                        ),
                      );
                    }),
                    Card(
                      color: remainingToPay > 0 ? Colors.orange.shade50 : Colors.green.shade50,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(color: remainingToPay > 0 ? Colors.orange.shade400 : Colors.green.shade400),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Сумма по чеку: ${totalCheckAmount.toStringAsFixed(2)} ₽ | Итого с чаевыми: ${totalWithTips.toStringAsFixed(2)} ₽',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Всего внесено: ${totalPaid.toStringAsFixed(2)} ₽',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                            const Divider(),
                            if (remainingToPay > 0)
                              Text(
                                '⚠️ ОСТАЛОСЬ ДОПЛАТИТЬ: ${remainingToPay.toStringAsFixed(2)} ₽',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.deepOrange.shade800),
                              )
                            else
                              Text(
                                '✅ СЧЕТ ЗАКРЫТ ПОЛНОСТЬЮ${(totalPaid - totalWithTips) > 0.01 ? " (переплата ${(totalPaid - totalWithTips).toStringAsFixed(2)} ₽)" : ""}',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.green.shade800),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  if (_members.isNotEmpty)
                    Card(
                      color: Colors.green.shade50,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(color: Colors.green.shade300),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.payments_outlined, color: Colors.green),
                                SizedBox(width: 8),
                                Text('КТО КОМУ ПЕРЕВОДИТ ДЕНЬГИ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                              ],
                            ),
                            const Divider(),
                            if (transfers.isEmpty)
                              const Text('Все в расчете, переводов не требуется.')
                            else
                              ...transfers.map((t) => Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4),
                                    child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                  )),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: () => _shareReport(finalTotals, transfers, effectivePaid, remainingToPay),
                              icon: const Icon(Icons.share),
                              label: const Text('Отправить расчет в чат (WhatsApp / Telegram)', style: TextStyle(fontSize: 15)),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
