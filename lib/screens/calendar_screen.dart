import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/note.dart';
import 'navigation.dart';

/// Month calendar of daily notes and of notes edited each day.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late DateTime _day = _dateOnly(DateTime.now());

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  void _shift(int months) =>
      setState(() => _month = DateTime(_month.year, _month.month + months));

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final paths = {for (final n in app.notes) n.path};
    final byDay = <DateTime, List<Note>>{};
    for (final n in app.notes) {
      byDay.putIfAbsent(_dateOnly(n.modified), () => []).add(n);
    }
    final first = _month;
    // Weeks start on Sunday.
    final lead = first.weekday % 7;
    final days = DateUtils.getDaysInMonth(first.year, first.month);
    final cells = ((lead + days) / 7).ceil() * 7;
    final today = _dateOnly(DateTime.now());
    final dayNotes = byDay[_day] ?? const <Note>[];
    final hasDaily = paths.contains(dailyNotePath(_day));
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final calendar = Column(
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left_rounded),
              onPressed: () => _shift(-1),
            ),
            Expanded(
              child: Text(
                DateFormat('yyyy년 M월', 'ko').format(_month),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right_rounded),
              onPressed: () => _shift(1),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final (i, w) in ['일', '월', '화', '수', '목', '금', '토'].indexed)
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: i == 0
                          ? scheme.error
                          : i == 6
                          ? scheme.primary
                          : scheme.outline,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: wide ? 1.1 : 0.9,
          children: [
            for (var c = 0; c < cells; c++)
              if (c < lead || c >= lead + days)
                const SizedBox()
              else
                _DayCell(
                  day: DateTime(first.year, first.month, c - lead + 1),
                  today: today,
                  selected: _day,
                  daily: paths.contains(
                    dailyNotePath(
                      DateTime(first.year, first.month, c - lead + 1),
                    ),
                  ),
                  edited:
                      byDay[DateTime(first.year, first.month, c - lead + 1)]
                          ?.length ??
                      0,
                  onTap: (d) => setState(() => _day = d),
                  onDoubleTap: (d) => openDailyNote(context, d),
                ),
          ],
        ),
      ],
    );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          DateFormat('M월 d일 EEEE', 'ko').format(_day),
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: () => openDailyNote(context, _day),
          icon: Icon(hasDaily ? Icons.event_note_rounded : Icons.add_rounded),
          label: Text(hasDaily ? '일일 노트 열기' : '일일 노트 만들기'),
        ),
        const SizedBox(height: 12),
        Text(
          '이날 수정한 메모 ${dayNotes.length}개',
          style: TextStyle(color: scheme.outline),
        ),
        for (final n in dayNotes)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              n.kind == NoteKind.drawing
                  ? Icons.draw_outlined
                  : Icons.description_outlined,
            ),
            title: Text(n.title),
            subtitle: Text(
              [
                if (n.folder.isNotEmpty) n.folder,
                DateFormat('HH:mm').format(n.modified),
              ].join(' · '),
            ),
            onTap: () => openNote(context, n.path),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('캘린더'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              _month = DateTime(today.year, today.month);
              _day = today;
            }),
            child: const Text('오늘'),
          ),
        ],
      ),
      body: SafeArea(
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: calendar,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 2,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: details,
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [calendar, const Divider(height: 32), details],
              ),
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.today,
    required this.selected,
    required this.daily,
    required this.edited,
    required this.onTap,
    required this.onDoubleTap,
  });

  final DateTime day;
  final DateTime today;
  final DateTime selected;
  final bool daily;
  final int edited;
  final ValueChanged<DateTime> onTap;
  final ValueChanged<DateTime> onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = day == selected;
    final isToday = day == today;
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Material(
        color: isSelected
            ? scheme.primary
            : daily
            ? scheme.primaryContainer
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isToday && !isSelected
              ? BorderSide(color: scheme.primary, width: 1.5)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onTap(day),
          onDoubleTap: () => onDoubleTap(day),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: TextStyle(
                  fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                  color: isSelected
                      ? scheme.onPrimary
                      : daily
                      ? scheme.onPrimaryContainer
                      : null,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < edited.clamp(0, 3); i++)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? scheme.onPrimary : scheme.tertiary,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
