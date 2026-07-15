/// COCO 80 类 + VOC 20 类 → YOLO class_id 映射表
///
/// 验证来源：
/// - server_final.py: names = voc_names if mdl=="voc" else coco_names
/// - dataset_coco.yaml: 0:person, 1:bicycle, ..., 79:toothbrush
/// - dataset_07_12.yaml: 0:aeroplane, ..., 19:tvmonitor
/// - prepare_coco.py: C = {cat['id']: i for i, cat in enumerate(d['categories'])}
///
/// 原版 COCO 标注 ID 有断号，prepare_coco.py 用 enumerate 重映射为连续 0~79。

/// COCO 80 类 类名→ID 映射（连续 0~79）
const Map<String, int> COCO_MAP = {
  "person": 0,
  "bicycle": 1,
  "car": 2,
  "motorcycle": 3,
  "airplane": 4,
  "bus": 5,
  "train": 6,
  "truck": 7,
  "boat": 8,
  "traffic light": 9,
  "fire hydrant": 10,
  "stop sign": 11,
  "parking meter": 12,
  "bench": 13,
  "bird": 14,
  "cat": 15,
  "dog": 16,
  "horse": 17,
  "sheep": 18,
  "cow": 19,
  "elephant": 20,
  "bear": 21,
  "zebra": 22,
  "giraffe": 23,
  "backpack": 24,
  "umbrella": 25,
  "handbag": 26,
  "tie": 27,
  "suitcase": 28,
  "frisbee": 29,
  "skis": 30,
  "snowboard": 31,
  "sports ball": 32,
  "kite": 33,
  "baseball bat": 34,
  "baseball glove": 35,
  "skateboard": 36,
  "surfboard": 37,
  "tennis racket": 38,
  "bottle": 39,
  "wine glass": 40,
  "cup": 41,
  "fork": 42,
  "knife": 43,
  "spoon": 44,
  "bowl": 45,
  "banana": 46,
  "apple": 47,
  "sandwich": 48,
  "orange": 49,
  "broccoli": 50,
  "carrot": 51,
  "hot dog": 52,
  "pizza": 53,
  "donut": 54,
  "cake": 55,
  "chair": 56,
  "couch": 57,
  "potted plant": 58,
  "bed": 59,
  "dining table": 60,
  "toilet": 61,
  "tv": 62,
  "laptop": 63,
  "mouse": 64,
  "remote": 65,
  "keyboard": 66,
  "cell phone": 67,
  "microwave": 68,
  "oven": 69,
  "toaster": 70,
  "sink": 71,
  "refrigerator": 72,
  "book": 73,
  "clock": 74,
  "vase": 75,
  "scissors": 76,
  "teddy bear": 77,
  "hair drier": 78,
  "toothbrush": 79,
};

/// VOC 20 类 类名→ID 映射（0~19）
const Map<String, int> VOC_MAP = {
  "aeroplane": 0,
  "bicycle": 1,
  "bird": 2,
  "boat": 3,
  "bottle": 4,
  "bus": 5,
  "car": 6,
  "cat": 7,
  "chair": 8,
  "cow": 9,
  "diningtable": 10,
  "dog": 11,
  "horse": 12,
  "motorbike": 13,
  "person": 14,
  "pottedplant": 15,
  "sheep": 16,
  "sofa": 17,
  "train": 18,
  "tvmonitor": 19,
};

/// 获取当前模型的类别列表（按 ID 排序）
List<String> getClassList({required bool isVoc}) {
  final map = isVoc ? VOC_MAP : COCO_MAP;
  final entries = map.entries.toList();
  entries.sort((a, b) => a.value.compareTo(b.value));
  return entries.map((e) => e.key).toList();
}
