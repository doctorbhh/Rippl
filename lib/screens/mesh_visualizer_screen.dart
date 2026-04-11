import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

/// Real-time mesh network visualizer screen.
/// Parses @EVT: prefixed BLE notifications and renders a force-directed graph.
class MeshVisualizerScreen extends ConsumerStatefulWidget {
  const MeshVisualizerScreen({super.key});

  @override
  ConsumerState<MeshVisualizerScreen> createState() =>
      _MeshVisualizerScreenState();
}

class _MeshVisualizerScreenState extends ConsumerState<MeshVisualizerScreen>
    with SingleTickerProviderStateMixin {
  // Graph state
  final Map<String, _MeshNode> _nodes = {};
  final Map<String, _MeshEdge> _edges = {};
  final List<_Pulse> _pulses = [];
  final List<_EventLog> _eventLog = [];
  String? _myNodeId;
  int _msgCount = 0;
  int _ackCount = 0;
  bool _showLog = false;

  // Animation
  late AnimationController _animController;
  StreamSubscription? _bleSubscription;

  // Physics constants
  static const double _repulsion = 600;
  static const double _springK = 0.03;
  static const double _springLen = 100;
  static const double _damping = 0.85;
  static const double _centerPull = 0.004;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    // [FIX L6] Run physics in animation tick, NOT in paint()
    _animController.addListener(() {
      _physicsStep();
      _advancePulses();
      setState(() {});
    });
    _startListening();
  }

  @override
  void dispose() {
    _animController.dispose();
    _bleSubscription?.cancel();
    super.dispose();
  }

  void _startListening() {
    final bm = ref.read(bluetoothManagerProvider);
    _bleSubscription = bm.receivedData.listen((data) {
      if (data.startsWith('@EVT:')) {
        try {
          final json = jsonDecode(data.substring(5)) as Map<String, dynamic>;
          _handleEvent(json);
        } catch (_) {}
      }
    });
  }

  void _handleEvent(Map<String, dynamic> evt) {
    final type = evt['e'] as String?;
    if (type == null) return;
    final now = DateTime.now();

    switch (type) {
      case 'topo':
        _myNodeId = evt['me'] as String?;
        if (_myNodeId != null) {
          _ensureNode(_myNodeId!, 0, 0, isMe: true);
        }
        final nodes = evt['nodes'] as List<dynamic>? ?? [];
        for (final n in nodes) {
          final id = n['id'] as String?;
          if (id == null) continue;
          _ensureNode(id, n['hop'] as int? ?? 1, n['rssi'] as int? ?? -70);
          if (_myNodeId != null) {
            final key = _edgeKey(_myNodeId!, id);
            _edges[key] = _MeshEdge(
              from: _myNodeId!,
              to: id,
              hop: n['hop'] as int? ?? 1,
            );
          }
        }
        break;

      case 'node_add':
        final id = evt['id'] as String?;
        if (id == null) break;
        _ensureNode(id, evt['hop'] as int? ?? 1, evt['rssi'] as int? ?? -70);
        _nodes[id]!.addedAt = now;
        if (_myNodeId != null) {
          _edges[_edgeKey(_myNodeId!, id)] = _MeshEdge(
            from: _myNodeId!,
            to: id,
            hop: evt['hop'] as int? ?? 1,
          );
        }
        break;

      case 'node_rm':
        final id = evt['id'] as String?;
        if (id == null) break;
        if (_nodes.containsKey(id)) {
          _nodes[id]!.health = 0;
          _nodes[id]!.removedAt = now;
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) {
              setState(() {
                _nodes.remove(id);
                _edges.removeWhere((k, _) => k.contains(id));
              });
            }
          });
        }
        break;

      case 'msg_tx':
        _msgCount++;
        if (_myNodeId != null) {
          for (final entry in _nodes.entries) {
            if (entry.key != _myNodeId && entry.value.hop == 1) {
              _pulses.add(_Pulse(
                from: _myNodeId!,
                to: entry.key,
                color: AppColors.safetyOrange,
              ));
            }
          }
        }
        break;

      case 'msg_rx':
        _msgCount++;
        final from = evt['from'] as String?;
        if (from != null && _myNodeId != null && _nodes.containsKey(from)) {
          _pulses.add(_Pulse(
            from: from,
            to: _myNodeId!,
            color: const Color(0xFF60A5FA),
          ));
        }
        break;

      case 'msg_relay':
        final to = evt['to'] as String?;
        if (to != null && _myNodeId != null && _nodes.containsKey(to)) {
          _pulses.add(_Pulse(
            from: _myNodeId!,
            to: to,
            color: const Color(0xFFA78BFA),
          ));
        }
        break;

      case 'ack_rx':
        _ackCount++;
        final from = evt['from'] as String?;
        if (from != null && _nodes.containsKey(from) && _myNodeId != null) {
          _pulses.add(_Pulse(
            from: from,
            to: _myNodeId!,
            color: AppColors.connected,
          ));
        }
        break;
    }

    _eventLog.insert(0, _EventLog(time: now, type: type, data: evt));
    if (_eventLog.length > 100) _eventLog.removeLast();
  }

  void _ensureNode(String id, int hop, int rssi, {bool isMe = false}) {
    if (!_nodes.containsKey(id)) {
      final rand = Random();
      _nodes[id] = _MeshNode(
        id: id,
        hop: hop,
        rssi: rssi,
        x: 0.5 + (rand.nextDouble() - 0.5) * 0.3,
        y: 0.5 + (rand.nextDouble() - 0.5) * 0.3,
        isMe: isMe,
        addedAt: DateTime.now(),
      );
    } else {
      _nodes[id]!.hop = hop;
      _nodes[id]!.rssi = rssi;
      _nodes[id]!.health = 1;
      _nodes[id]!.removedAt = null;
      if (isMe) _nodes[id]!.isMe = true;
    }
  }

  String _edgeKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a-$b' : '$b-$a';

  /// [FIX L6] Physics step moved here from CustomPainter.paint()
  void _physicsStep() {
    final size = MediaQuery.of(context).size;
    final nodeList = _nodes.values.where((n) => n.health > 0).toList();

    // Repulsion between pairs
    for (int i = 0; i < nodeList.length; i++) {
      for (int j = i + 1; j < nodeList.length; j++) {
        final a = nodeList[i], b = nodeList[j];
        double dx = (b.x - a.x) * size.width;
        double dy = (b.y - a.y) * size.height;
        double dist = sqrt(dx * dx + dy * dy).clamp(1, double.infinity);
        double force = _repulsion / (dist * dist);
        double fx = (dx / dist) * force / size.width;
        double fy = (dy / dist) * force / size.height;
        a.vx -= fx;
        a.vy -= fy;
        b.vx += fx;
        b.vy += fy;
      }
    }

    // Spring along edges
    for (final edge in _edges.values) {
      final a = _nodes[edge.from], b = _nodes[edge.to];
      if (a == null || b == null) continue;
      double dx = (b.x - a.x) * size.width;
      double dy = (b.y - a.y) * size.height;
      double dist = sqrt(dx * dx + dy * dy).clamp(1, double.infinity);
      double force = _springK * (dist - _springLen);
      double fx = (dx / dist) * force / size.width;
      double fy = (dy / dist) * force / size.height;
      a.vx += fx;
      a.vy += fy;
      b.vx -= fx;
      b.vy -= fy;
    }

    // Center pull + damping + position update
    for (final n in nodeList) {
      n.vx += (0.5 - n.x) * _centerPull;
      n.vy += (0.5 - n.y) * _centerPull;
      n.vx *= _damping;
      n.vy *= _damping;
      n.x = (n.x + n.vx).clamp(0.05, 0.95);
      n.y = (n.y + n.vy).clamp(0.05, 0.95);
    }
  }

  /// Advance pulse animations
  void _advancePulses() {
    for (int i = _pulses.length - 1; i >= 0; i--) {
      _pulses[i].progress += _Pulse.speed;
      if (_pulses[i].progress >= 1) _pulses.removeAt(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectionStatus = ref.watch(connectionStatusProvider);
    final isConnected = connectionStatus == ConnectionStatus.connected;
    final aliveNodes =
        _nodes.values.where((n) => n.health > 0).length;
    final ackRate =
        _msgCount > 0 ? (_ackCount / _msgCount * 100).round() : 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mesh Visualizer'),
        actions: [
          IconButton(
            icon: Icon(_showLog ? Icons.hub : Icons.list_alt),
            tooltip: _showLog ? 'Show Graph' : 'Show Log',
            onPressed: () => setState(() => _showLog = !_showLog),
          ),
        ],
      ),
      body: Column(
        children: [
          // Stats bar
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: const BoxDecoration(
              color: AppColors.slateGray,
              border: Border(
                bottom: BorderSide(color: AppColors.cardBackground),
              ),
            ),
            child: Row(
              children: [
                _StatChip(
                  icon: Icons.circle,
                  iconColor: isConnected
                      ? AppColors.connected
                      : AppColors.disconnected,
                  label: isConnected ? 'Online' : 'Offline',
                ),
                const SizedBox(width: 12),
                _StatChip(
                  icon: Icons.hub,
                  iconColor: AppColors.safetyOrange,
                  label: '$aliveNodes nodes',
                ),
                const SizedBox(width: 12),
                _StatChip(
                  icon: Icons.chat_bubble,
                  iconColor: const Color(0xFF60A5FA),
                  label: '$_msgCount msgs',
                ),
                const SizedBox(width: 12),
                _StatChip(
                  icon: Icons.check_circle,
                  iconColor: AppColors.connected,
                  label: '$ackRate% ACK',
                ),
              ],
            ),
          ),

          // Main content
          Expanded(
            child: _showLog ? _buildEventLog() : _buildGraph(),
          ),

          // Legend bar
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: const BoxDecoration(
              color: AppColors.slateGray,
              border: Border(
                top: BorderSide(color: AppColors.cardBackground),
              ),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _LegendItem(color: AppColors.safetyOrange, label: 'You'),
                _LegendItem(color: AppColors.connected, label: '1-hop'),
                _LegendItem(color: Color(0xFF60A5FA), label: '2-hop'),
                _LegendItem(
                  color: AppColors.disconnected,
                  label: 'Timeout',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGraph() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          painter: _MeshPainter(
            nodes: _nodes,
            edges: _edges,
            pulses: _pulses,
            myNodeId: _myNodeId,
          ),
          size: Size(constraints.maxWidth, constraints.maxHeight),
          child: _nodes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
               Icon(Icons.hub, size: 64, color: AppColors.textMuted.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      Text(
                        'Connect to ESP32 to see mesh',
                        style: AppTextStyles.body1.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Events will appear here in real-time',
                        style: AppTextStyles.caption,
                      ),
                    ],
                  ),
                )
              : const SizedBox.expand(),
        );
      },
    );
  }

  Widget _buildEventLog() {
    if (_eventLog.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.list_alt, size: 64,
                color: AppColors.textMuted.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text('No events yet',
                style: AppTextStyles.body1
                    .copyWith(color: AppColors.textMuted)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.sm),
      itemCount: _eventLog.length,
      itemBuilder: (context, index) {
        final e = _eventLog[index];
        final time =
            '${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}:${e.time.second.toString().padLeft(2, '0')}';

        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.cardBackground.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border(
              left: BorderSide(color: _eventColor(e.type), width: 3),
            ),
          ),
          child: Row(
            children: [
              Text(time,
                  style: AppTextStyles.caption
                      .copyWith(fontFamily: 'monospace')),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _eventColor(e.type).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  e.type,
                  style: AppTextStyles.caption.copyWith(
                    color: _eventColor(e.type),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _formatEvent(e),
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Color _eventColor(String type) {
    switch (type) {
      case 'node_add':
        return AppColors.connected;
      case 'node_rm':
        return AppColors.disconnected;
      case 'msg_tx':
        return AppColors.safetyOrange;
      case 'msg_rx':
        return const Color(0xFF60A5FA);
      case 'msg_relay':
        return const Color(0xFFA78BFA);
      case 'ack_rx':
        return const Color(0xFF34D399);
      case 'topo':
        return AppColors.warning;
      default:
        return AppColors.textMuted;
    }
  }

  String _formatEvent(_EventLog e) {
    final d = e.data;
    switch (e.type) {
      case 'node_add':
        return '${d['id']} joined (hop:${d['hop']} rssi:${d['rssi']})';
      case 'node_rm':
        return '${d['id']} timed out';
      case 'msg_tx':
        return '#${d['mid']} sent → ${d['to']}';
      case 'msg_rx':
        return '#${d['mid']} from ${d['from']} (${d['hop']} hops)';
      case 'msg_relay':
        return '#${d['mid']} relayed → ${d['to']}';
      case 'ack_rx':
        return '#${d['mid']} ACK from ${d['from']} ✓';
      case 'topo':
        final nodes = d['nodes'] as List<dynamic>? ?? [];
        return '${nodes.length} nodes in table';
      default:
        return jsonEncode(d);
    }
  }
}

// ═══════════════════════════════════════════════
// DATA CLASSES
// ═══════════════════════════════════════════════
class _MeshNode {
  String id;
  int hop;
  int rssi;
  double x, y; // normalized 0..1
  double vx = 0, vy = 0;
  double health = 1;
  bool isMe;
  DateTime addedAt;
  DateTime? removedAt;

  _MeshNode({
    required this.id,
    required this.hop,
    required this.rssi,
    required this.x,
    required this.y,
    this.isMe = false,
    required this.addedAt,
  });
}

class _MeshEdge {
  final String from, to;
  final int hop;
  _MeshEdge({required this.from, required this.to, required this.hop});
}

class _Pulse {
  final String from, to;
  final Color color;
  double progress = 0;
  static const double speed = 0.025;
  _Pulse({required this.from, required this.to, required this.color});
}

class _EventLog {
  final DateTime time;
  final String type;
  final Map<String, dynamic> data;
  _EventLog({required this.time, required this.type, required this.data});
}

// ═══════════════════════════════════════════════
// CUSTOM PAINTER — Force-Directed Graph
// ═══════════════════════════════════════════════
class _MeshPainter extends CustomPainter {
  final Map<String, _MeshNode> nodes;
  final Map<String, _MeshEdge> edges;
  final List<_Pulse> pulses;
  final String? myNodeId;

  _MeshPainter({
    required this.nodes,
    required this.edges,
    required this.pulses,
    required this.myNodeId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    // Draw edges
    for (final edge in edges.values) {
      final a = nodes[edge.from];
      final b = nodes[edge.to];
      if (a == null || b == null) continue;

      final ax = a.x * size.width, ay = a.y * size.height;
      final bx = b.x * size.width, by = b.y * size.height;

      final paint = Paint()
        ..strokeWidth = edge.hop == 1 ? 2 : 1
        ..color = edge.hop == 1
            ? const Color(0xFF4ADE80).withValues(alpha: 0.3)
            : const Color(0xFF60A5FA).withValues(alpha: 0.2);

      canvas.drawLine(Offset(ax, ay), Offset(bx, by), paint);
    }

    // Draw pulses
    for (final p in pulses) {
      final a = nodes[p.from];
      final b = nodes[p.to];
      if (a == null || b == null) continue;

      final ax = a.x * size.width, ay = a.y * size.height;
      final bx = b.x * size.width, by = b.y * size.height;
      final px = ax + (bx - ax) * p.progress;
      final py = ay + (by - ay) * p.progress;

      // Trail
      final trailStart = (p.progress - 0.15).clamp(0.0, 1.0);
      final tsx = ax + (bx - ax) * trailStart;
      final tsy = ay + (by - ay) * trailStart;
      canvas.drawLine(
        Offset(tsx, tsy),
        Offset(px, py),
        Paint()
          ..color = p.color.withValues(alpha: 0.4)
          ..strokeWidth = 3,
      );

      // Dot
      canvas.drawCircle(Offset(px, py), 5, Paint()..color = p.color);

      // Glow
      final glowPaint = Paint()
        ..shader = RadialGradient(
          colors: [p.color.withValues(alpha: 0.4), p.color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: Offset(px, py), radius: 14));
      canvas.drawCircle(Offset(px, py), 14, glowPaint);
    }

    // Draw nodes
    final now = DateTime.now();
    for (final node in nodes.values) {
      final cx = node.x * size.width;
      final cy = node.y * size.height;
      final radius = 20.0;

      double alpha = 1.0;
      if (now.difference(node.addedAt).inMilliseconds < 1000) {
        alpha = now.difference(node.addedAt).inMilliseconds / 1000.0;
      }
      if (node.removedAt != null) {
        alpha = (1 - now.difference(node.removedAt!).inMilliseconds / 2000.0)
            .clamp(0.0, 1.0);
      }
      if (alpha <= 0) continue;

      // Glow ring
      Color glowColor;
      if (node.removedAt != null) {
        glowColor = const Color(0xFFEF4444);
      } else if (node.isMe) {
        glowColor = const Color(0xFFFF6B35);
      } else if (node.hop == 1) {
        glowColor = const Color(0xFF4ADE80);
      } else {
        glowColor = const Color(0xFF60A5FA);
      }

      final glowPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            glowColor.withValues(alpha: 0.25 * alpha),
            glowColor.withValues(alpha: 0),
          ],
        ).createShader(
            Rect.fromCircle(center: Offset(cx, cy), radius: radius + 8));
      canvas.drawCircle(Offset(cx, cy), radius + 8, glowPaint);

      // Node body
      Color bodyColor;
      if (node.removedAt != null) {
        bodyColor = const Color(0xFFEF4444);
      } else if (node.isMe) {
        bodyColor = const Color(0xFFFF8C42);
      } else if (node.hop == 1) {
        bodyColor = const Color(0xFF2D6A4F);
      } else {
        bodyColor = const Color(0xFF1E40AF);
      }

      canvas.drawCircle(
        Offset(cx, cy),
        radius,
        Paint()..color = bodyColor.withValues(alpha: alpha),
      );
      canvas.drawCircle(
        Offset(cx, cy),
        radius,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.1 * alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

      // Label
      final textPainter = TextPainter(
        text: TextSpan(
          text: node.id,
          style: TextStyle(
            color: Colors.white.withValues(alpha: alpha),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(cx - textPainter.width / 2, cy - textPainter.height / 2),
      );

      // Sub-label
      final sub = node.isMe ? 'YOU' : '${node.hop}h';
      final subPainter = TextPainter(
        text: TextSpan(
          text: sub,
          style: TextStyle(
            color: (node.isMe
                    ? const Color(0xFFFF8C42)
                    : const Color(0xFF9BA4B5))
                .withValues(alpha: 0.7 * alpha),
            fontSize: 8,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      subPainter.paint(
        canvas,
        Offset(cx - subPainter.width / 2, cy + radius + 4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ═══════════════════════════════════════════════
// WIDGETS
// ═══════════════════════════════════════════════
class _StatChip extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;

  const _StatChip({
    required this.icon,
    required this.iconColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 8, color: iconColor),
        const SizedBox(width: 4),
        Text(label, style: AppTextStyles.caption),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: AppTextStyles.caption),
      ],
    );
  }
}
