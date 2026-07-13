import 'package:flutter/material.dart';

class ModelSelector extends StatefulWidget {
  final String currentModel;
  final ValueChanged<String> onModelChanged;

  const ModelSelector({
    super.key,
    required this.currentModel,
    required this.onModelChanged,
  });

  @override
  State<ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends State<ModelSelector> {
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: (v) => widget.onModelChanged(v),
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: 'voc',
          checked: widget.currentModel == 'voc',
          child: const Row(
            children: [
              Text('VOC (20类)'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'coco',
          checked: widget.currentModel == 'coco',
          child: const Row(
            children: [
              Icon(Icons.check, size: 18, color: Color(0xFF22C55E)),
              SizedBox(width: 8),
              Text('COCO (80类)'),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFBFDBFE)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.model_training, size: 16, color: Color(0xFF3B82F6)),
            const SizedBox(width: 6),
            Text(widget.currentModel == 'voc' ? 'VOC (20类)' : 'COCO (80类)',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF3B82F6))),
            const Icon(Icons.arrow_drop_down, size: 18, color: Color(0xFF3B82F6)),
          ],
        ),
      ),
    );
  }
}
