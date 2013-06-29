#!/usr/bin/env lua


do


local _parse_sql_actions = { [0] =
  0, 1, 0, 1, 1, 2, 0, 2, 2, 0, 9, 2, 0, 10, 2, 0, 11, 2, 0, 13, 
  2, 1, 2, 2, 1, 6, 3, 0, 3, 4, 3, 0, 3, 5, 3, 0, 3, 7, 3, 0, 
  3, 8, 3, 0, 3, 12, 4, 0, 2, 3, 7, 4, 0, 3, 8, 11
};

local _parse_sql_trans_keys = { [0] =
  0, 0, 45, 45, 10, 10, 42, 42, 10, 42, 10, 47, 82, 82, 
  69, 69, 65, 65, 84, 84, 69, 69, 32, 32, 68, 84, 65, 
  65, 84, 84, 65, 65, 66, 66, 65, 65, 83, 83, 69, 69, 
  9, 47, 9, 96, 45, 45, 10, 10, 42, 42, 10, 42, 10, 47, 
  10, 96, 10, 96, 9, 47, 9, 59, 45, 45, 10, 10, 42, 
  42, 10, 42, 10, 47, 65, 65, 66, 66, 76, 76, 69, 69, 
  32, 32, 73, 96, 70, 70, 32, 32, 78, 78, 79, 79, 84, 84, 
  32, 32, 69, 69, 88, 88, 73, 73, 83, 83, 84, 84, 83, 
  83, 32, 32, 96, 96, 10, 96, 10, 96, 32, 32, 40, 40, 
  10, 10, 32, 41, 32, 32, 75, 96, 69, 69, 89, 89, 32, 32, 
  96, 96, 10, 96, 10, 96, 10, 10, 82, 82, 73, 73, 77, 
  77, 65, 65, 82, 82, 89, 89, 32, 32, 75, 75, 69, 69, 
  89, 89, 32, 32, 78, 78, 73, 73, 81, 81, 85, 85, 69, 69, 
  32, 32, 75, 75, 10, 96, 10, 96, 10, 10, 10, 59, 10, 
  59, 82, 82, 79, 79, 80, 80, 32, 32, 84, 84, 65, 65, 
  66, 66, 76, 76, 69, 69, 32, 32, 73, 73, 70, 70, 32, 32, 
  69, 69, 88, 88, 73, 73, 83, 83, 84, 84, 83, 83, 32, 
  32, 96, 96, 10, 96, 10, 96, 59, 59, 78, 78, 83, 83, 
  69, 69, 82, 82, 84, 84, 32, 32, 73, 73, 78, 78, 84, 84, 
  79, 79, 32, 32, 96, 96, 10, 96, 10, 96, 32, 32, 40, 
  86, 10, 41, 32, 32, 86, 86, 65, 65, 76, 76, 85, 85, 
  69, 69, 83, 83, 32, 32, 40, 40, 39, 78, 10, 92, 10, 92, 
  41, 44, 44, 59, 32, 78, 48, 57, 41, 57, 48, 57, 41, 
  57, 85, 85, 76, 76, 76, 76, 34, 116, 79, 79, 67, 67, 
  75, 75, 32, 32, 84, 84, 65, 65, 66, 66, 76, 76, 69, 69, 
  83, 83, 32, 32, 96, 96, 10, 96, 10, 96, 32, 32, 87, 
  87, 82, 82, 73, 73, 84, 84, 69, 69, 69, 69, 84, 84, 
  32, 32, 10, 59, 10, 59, 78, 83, 76, 76, 79, 79, 67, 67, 
  75, 75, 32, 32, 84, 84, 65, 65, 66, 66, 76, 76, 69, 
  69, 83, 83, 69, 69, 9, 85, 0
};

local _parse_sql_key_spans = { [0] =
  0, 1, 1, 1, 33, 38, 1, 1, 1, 1, 1, 1, 17, 1, 1, 1, 1, 1, 1, 1, 
  39, 88, 1, 1, 1, 33, 38, 87, 87, 39, 51, 1, 1, 1, 33, 38, 1, 1, 1, 1, 
  1, 24, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 87, 87, 1, 1, 
  1, 10, 1, 22, 1, 1, 1, 1, 87, 87, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 87, 87, 1, 50, 50, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 87, 87, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 87, 87, 1, 47, 32, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 40, 83, 83, 4, 16, 47, 10, 17, 10, 17, 1, 1, 1, 83, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 87, 87, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 50, 50, 6, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 77
};

local _parse_sql_index_offsets = { [0] =
  0, 0, 2, 4, 6, 40, 79, 81, 83, 85, 87, 89, 91, 109, 111, 113, 115, 117, 119, 121, 
  123, 163, 252, 254, 256, 258, 292, 331, 419, 507, 547, 599, 601, 603, 605, 639, 678, 680, 682, 684, 
  686, 688, 713, 715, 717, 719, 721, 723, 725, 727, 729, 731, 733, 735, 737, 739, 741, 829, 917, 919, 
  921, 923, 934, 936, 959, 961, 963, 965, 967, 1055, 1143, 1145, 1147, 1149, 1151, 1153, 1155, 1157, 1159, 1161, 
  1163, 1165, 1167, 1169, 1171, 1173, 1175, 1177, 1179, 1181, 1269, 1357, 1359, 1410, 1461, 1463, 1465, 1467, 1469, 1471, 
  1473, 1475, 1477, 1479, 1481, 1483, 1485, 1487, 1489, 1491, 1493, 1495, 1497, 1499, 1501, 1503, 1591, 1679, 1681, 1683, 
  1685, 1687, 1689, 1691, 1693, 1695, 1697, 1699, 1701, 1703, 1705, 1793, 1881, 1883, 1931, 1964, 1966, 1968, 1970, 1972, 
  1974, 1976, 1978, 1980, 1982, 2023, 2107, 2191, 2196, 2213, 2261, 2272, 2290, 2301, 2319, 2321, 2323, 2325, 2409, 2411, 
  2413, 2415, 2417, 2419, 2421, 2423, 2425, 2427, 2429, 2431, 2433, 2521, 2609, 2611, 2613, 2615, 2617, 2619, 2621, 2623, 
  2625, 2627, 2678, 2729, 2736, 2738, 2740, 2742, 2744, 2746, 2748, 2750, 2752, 2754, 2756, 2758, 2760
};

local _parse_sql_indicies = { [0] =
  0, 1, 2, 0, 3, 1, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 
  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 5, 3, 
  4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 
  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 5, 3, 3, 3, 3, 6, 3, 7, 
  1, 8, 1, 9, 1, 10, 1, 11, 1, 12, 1, 13, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 14, 1, 15, 1, 16, 1, 17, 1, 18, 1, 19, 1, 20, 
  1, 21, 1, 22, 23, 22, 22, 22, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 22, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 24, 
  1, 25, 1, 22, 23, 22, 22, 22, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 22, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 24, 
  1, 25, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 26, 1, 27, 1, 23, 27, 28, 1, 29, 28, 
  28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 
  28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 30, 28, 29, 28, 28, 28, 28, 28, 28, 28, 
  28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 
  28, 28, 28, 28, 30, 28, 28, 28, 28, 22, 28, 32, 31, 31, 31, 31, 31, 31, 31, 31, 
  31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 
  31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 
  31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 
  31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 1, 31, 32, 
  31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 
  31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 
  31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 
  31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 
  31, 31, 31, 31, 31, 33, 31, 34, 35, 34, 34, 34, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 34, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 36, 1, 37, 1, 34, 35, 34, 34, 34, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 34, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 36, 1, 37, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 1, 38, 
  1, 35, 38, 39, 1, 40, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 
  39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 41, 39, 40, 
  39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 
  39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 39, 41, 39, 39, 39, 39, 34, 39, 42, 1, 
  43, 1, 44, 1, 45, 1, 46, 1, 47, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 48, 1, 49, 1, 50, 1, 51, 1, 52, 
  1, 53, 1, 54, 1, 55, 1, 56, 1, 57, 1, 58, 1, 59, 1, 60, 1, 61, 1, 48, 
  1, 63, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 
  62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 
  62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 
  62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 62, 
  62, 62, 62, 62, 62, 62, 62, 1, 62, 65, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 
  64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 
  64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 
  64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 
  64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 66, 64, 67, 1, 68, 
  1, 69, 1, 70, 1, 1, 1, 1, 1, 1, 1, 1, 71, 1, 72, 1, 73, 1, 1, 1, 
  1, 74, 1, 1, 1, 1, 75, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 76, 1, 77, 
  1, 78, 1, 79, 1, 80, 1, 82, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 1, 81, 82, 81, 81, 81, 81, 
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 
  81, 83, 81, 69, 83, 84, 1, 85, 1, 86, 1, 87, 1, 88, 1, 89, 1, 90, 1, 91, 
  1, 92, 1, 93, 1, 83, 1, 94, 1, 95, 1, 96, 1, 97, 1, 98, 1, 99, 1, 73, 
  1, 101, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 
  100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 
  100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 
  100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 
  100, 100, 100, 100, 100, 100, 100, 1, 100, 103, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 
  102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 
  102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 
  102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 
  102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 104, 102, 105, 83, 106, 
  71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 
  71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 
  71, 71, 71, 71, 71, 71, 71, 71, 107, 71, 108, 71, 71, 71, 71, 71, 71, 71, 71, 71, 
  71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 
  71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 71, 107, 
  71, 109, 1, 110, 1, 111, 1, 112, 1, 113, 1, 114, 1, 115, 1, 116, 1, 117, 1, 118, 
  1, 119, 1, 120, 1, 121, 1, 122, 1, 123, 1, 124, 1, 125, 1, 126, 1, 127, 1, 128, 
  1, 129, 1, 131, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 
  130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 
  130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 
  130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 
  130, 130, 130, 130, 130, 130, 130, 130, 130, 1, 130, 131, 130, 130, 130, 130, 130, 130, 130, 130, 
  130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 
  130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 
  130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 
  130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 130, 132, 130, 6, 
  1, 133, 1, 134, 1, 135, 1, 136, 1, 137, 1, 138, 1, 139, 1, 140, 1, 141, 1, 142, 
  1, 143, 1, 144, 1, 146, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 
  145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 
  145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 
  145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 
  145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 145, 1, 145, 148, 147, 147, 147, 147, 147, 147, 
  147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 
  147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 
  147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 
  147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 147, 149, 
  147, 150, 1, 151, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 152, 1, 153, 151, 151, 151, 151, 151, 151, 151, 151, 
  151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 151, 
  151, 151, 154, 151, 155, 1, 152, 1, 156, 1, 157, 1, 158, 1, 159, 1, 160, 1, 161, 1, 
  162, 1, 163, 1, 1, 1, 1, 1, 164, 1, 1, 165, 165, 165, 165, 165, 165, 165, 165, 165, 
  165, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 166, 1, 168, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 
  167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 169, 167, 167, 167, 167, 167, 167, 167, 
  167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 
  167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 167, 
  167, 167, 167, 167, 167, 170, 167, 172, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 
  171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 173, 171, 171, 171, 
  171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 
  171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 171, 
  171, 171, 171, 171, 171, 171, 171, 171, 171, 174, 171, 175, 1, 1, 176, 1, 161, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 177, 1, 178, 1, 1, 1, 1, 1, 1, 
  163, 1, 1, 1, 1, 1, 164, 1, 1, 165, 165, 165, 165, 165, 165, 165, 165, 165, 165, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 166, 
  1, 179, 179, 179, 179, 179, 179, 179, 179, 179, 179, 1, 180, 1, 1, 181, 1, 182, 1, 179, 
  179, 179, 179, 179, 179, 179, 179, 179, 179, 1, 183, 183, 183, 183, 183, 183, 183, 183, 183, 183, 
  1, 180, 1, 1, 181, 1, 1, 1, 183, 183, 183, 183, 183, 183, 183, 183, 183, 183, 1, 184, 
  1, 185, 1, 186, 1, 171, 1, 1, 171, 1, 171, 1, 1, 1, 1, 1, 1, 1, 1, 171, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 171, 1, 171, 1, 1, 171, 1, 1, 171, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 171, 1, 1, 1, 171, 1, 171, 1, 187, 1, 188, 1, 189, 1, 190, 1, 191, 1, 192, 
  1, 193, 1, 194, 1, 195, 1, 196, 1, 197, 1, 198, 1, 200, 199, 199, 199, 199, 199, 199, 
  199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 
  199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 
  199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 
  199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 1, 
  199, 200, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 
  199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 
  199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 
  199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 199, 
  199, 199, 199, 199, 199, 199, 199, 201, 199, 202, 1, 203, 1, 204, 1, 205, 1, 206, 1, 132, 
  1, 207, 1, 208, 1, 209, 1, 210, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 
  209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 
  209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 211, 209, 2, 209, 
  209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 
  209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 209, 
  209, 209, 209, 209, 209, 209, 209, 211, 209, 212, 1, 1, 1, 1, 213, 1, 214, 1, 215, 1, 
  216, 1, 217, 1, 218, 1, 219, 1, 220, 1, 221, 1, 222, 1, 223, 1, 132, 1, 127, 1, 
  6, 2, 6, 6, 6, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 6, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 224, 1, 225, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 6, 1, 1, 1, 1, 1, 1, 1, 226, 227, 
  1, 1, 1, 1, 228, 1, 1, 229, 1, 1, 1, 1, 1, 1, 230, 1, 231, 1, 0
};

local _parse_sql_trans_targs = { [0] =
  2, 0, 196, 4, 4, 5, 196, 7, 8, 9, 10, 11, 12, 13, 36, 14, 15, 16, 17, 18, 
  19, 20, 21, 21, 22, 24, 27, 23, 25, 25, 26, 28, 28, 29, 30, 30, 31, 33, 32, 34, 
  34, 35, 37, 38, 39, 40, 41, 42, 56, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 
  54, 55, 57, 57, 57, 57, 58, 59, 60, 61, 62, 92, 63, 64, 71, 82, 89, 65, 66, 67, 
  68, 69, 69, 70, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 83, 84, 85, 86, 87, 88, 
  90, 90, 90, 90, 91, 70, 92, 93, 196, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 
  106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 116, 117, 119, 120, 121, 122, 123, 124, 125, 
  126, 127, 128, 129, 130, 131, 131, 131, 131, 132, 133, 134, 137, 134, 135, 136, 138, 139, 140, 141, 
  142, 143, 144, 145, 150, 151, 154, 146, 146, 147, 157, 146, 146, 147, 157, 148, 149, 196, 144, 151, 
  148, 149, 152, 153, 155, 156, 147, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 
  171, 172, 173, 174, 175, 176, 177, 179, 180, 181, 181, 182, 184, 195, 185, 186, 187, 188, 189, 190, 
  191, 192, 193, 194, 1, 3, 6, 94, 118, 158, 178, 183
};

local _parse_sql_trans_actions = { [0] =
  1, 0, 3, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 3, 1, 1, 1, 1, 1, 3, 1, 1, 3, 1, 1, 3, 1, 1, 1, 1, 
  3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 5, 20, 1, 3, 30, 1, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  5, 20, 1, 3, 26, 3, 3, 1, 23, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 5, 20, 1, 3, 42, 1, 1, 1, 3, 1, 1, 1, 1, 1, 1, 
  1, 1, 11, 1, 5, 5, 1, 5, 20, 46, 5, 1, 3, 34, 1, 14, 1, 17, 1, 1, 
  51, 38, 1, 1, 1, 1, 8, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
};

local parse_sql_start = 196;
local parse_sql_first_final = 196;
local parse_sql_error = 0;

local parse_sql_en_main = 196;




local _sql_unescapes = setmetatable({
	["\\0"] = "\0";
	["\\'"] = "'";
	["\\\""] = "\"";
	["\\b"] = "\b";
	["\\n"] = "\n";
	["\\r"] = "\r";
	["\\t"] = "\t";
	["\\Z"] = "\26";
	["\\\\"] = "\\";
	["\\%"] = "%";
	["\\_"] = "_";
},{ __index = function(t, s) assert(false, "Unknown escape sequences: "..s); end });

function parse_sql(data, h)
	local p = 1;
	local pe = #data + 1;
	local cs;

	local pos_char, pos_line = 1, 1;

	local mark, token;
	local table_name, columns, value_lists, value_list, value_count;

	
  cs = parse_sql_start;

--  ragel flat exec

  local testEof = false;
  local _slen = 0;
  local _trans = 0;
  local _keys = 0;
  local _inds = 0;
  local _acts = 0;
  local _nacts = 0;
  local _tempval = 0;
  local _goto_level = 0;
  local _resume = 10;
  local _eof_trans = 15;
  local _again = 20;
  local _test_eof = 30;
  local _out = 40;

  while true do -- goto loop
  local _continue = false;
  repeat
    local _trigger_goto = false;
    if _goto_level <= 0 then

-- noEnd
      if p == pe then
        _goto_level = _test_eof;
        _continue = true; break;
      end


-- errState != 0
      if cs == 0 then
        _goto_level = _out;
       _continue = true; break;
      end
    end -- _goto_level <= 0

     if _goto_level <= _resume then
      _keys = cs * 2; -- LOCATE_TRANS
      _inds = _parse_sql_index_offsets[cs];
      _slen = _parse_sql_key_spans[cs];

      if   _slen > 0 and 
         _parse_sql_trans_keys[_keys] <= data:byte(p) and 
         data:byte(p) <= _parse_sql_trans_keys[_keys + 1] then 
        _trans = _parse_sql_indicies[ _inds + data:byte(p) - _parse_sql_trans_keys[_keys] ]; 
      else _trans =_parse_sql_indicies[ _inds + _slen ]; end

    cs = _parse_sql_trans_targs[_trans];

    if _parse_sql_trans_actions[_trans] ~= 0 then
      _acts = _parse_sql_trans_actions[_trans];
      _nacts = _parse_sql_actions[_acts];
      _acts = _acts + 1;

      while _nacts > 0 do
        _nacts = _nacts - 1;
        _acts = _acts + 1;
        _tempval = _parse_sql_actions[_acts - 1];

     -- start action switch
        if _tempval  == 0 then --4 FROM_STATE_ACTION_SWITCH
-- line 34 "sql.rl" -- end of line directive
       pos_char = pos_char + 1;       -- ACTION
        elseif _tempval  == 1 then --4 FROM_STATE_ACTION_SWITCH
-- line 35 "sql.rl" -- end of line directive
       pos_line = pos_line + 1; pos_char = 1;       -- ACTION
        elseif _tempval  == 2 then --4 FROM_STATE_ACTION_SWITCH
-- line 38 "sql.rl" -- end of line directive
       mark = p;       -- ACTION
        elseif _tempval  == 3 then --4 FROM_STATE_ACTION_SWITCH
-- line 39 "sql.rl" -- end of line directive
       token = data:sub(mark, p-1);       -- ACTION
        elseif _tempval  == 4 then --4 FROM_STATE_ACTION_SWITCH
-- line 52 "sql.rl" -- end of line directive
       table.insert(columns, token); columns[#columns] = token;       -- ACTION
        elseif _tempval  == 5 then --4 FROM_STATE_ACTION_SWITCH
-- line 58 "sql.rl" -- end of line directive
       table_name,columns = token,{};       -- ACTION
        elseif _tempval  == 6 then --4 FROM_STATE_ACTION_SWITCH
-- line 59 "sql.rl" -- end of line directive
       h.create(table_name, columns);       -- ACTION
        elseif _tempval  == 7 then --4 FROM_STATE_ACTION_SWITCH
-- line 65 "sql.rl" -- end of line directive
      
			value_count = value_count + 1; value_list[value_count] = token:gsub("\\.", _sql_unescapes);
		      -- ACTION
        elseif _tempval  == 8 then --4 FROM_STATE_ACTION_SWITCH
-- line 68 "sql.rl" -- end of line directive
       value_count = value_count + 1; value_list[value_count] = tonumber(token);       -- ACTION
        elseif _tempval  == 9 then --4 FROM_STATE_ACTION_SWITCH
-- line 69 "sql.rl" -- end of line directive
       value_count = value_count + 1;       -- ACTION
        elseif _tempval  == 10 then --4 FROM_STATE_ACTION_SWITCH
-- line 71 "sql.rl" -- end of line directive
       value_list,value_count = {},0;       -- ACTION
        elseif _tempval  == 11 then --4 FROM_STATE_ACTION_SWITCH
-- line 71 "sql.rl" -- end of line directive
       table.insert(value_lists, value_list);       -- ACTION
        elseif _tempval  == 12 then --4 FROM_STATE_ACTION_SWITCH
-- line 74 "sql.rl" -- end of line directive
       table_name,value_lists = token,{};       -- ACTION
        elseif _tempval  == 13 then --4 FROM_STATE_ACTION_SWITCH
-- line 75 "sql.rl" -- end of line directive
       h.insert(table_name, value_lists);       -- ACTION
        end
-- line 355 "sql.lua" -- end of line directive
    -- end action switch
      end -- while _nacts
    end

    if _trigger_goto then _continue = true; break; end
    end -- endif 

    if _goto_level <= _again then
      if cs == 0 then
        _goto_level = _out;
        _continue = true; break;
      end
      p = p + 1;
      if p ~= pe then
        _goto_level = _resume;
        _continue = true; break;
      end
    end -- _goto_level <= _again

    if _goto_level <= _test_eof then
    end -- _goto_level <= _test_eof

    if _goto_level <= _out then break; end
  _continue = true;
  until true;
  if not _continue then break; end
  end -- endif _goto_level <= out

  -- end of execute block


	if cs < parse_sql_first_final then
		print("parse_sql: there was an error, line "..pos_line.." column "..pos_char);
	else
		print("Success. EOF at line "..pos_line.." column "..pos_char)
	end
end

end

-- import modules
package.path = package.path.."..\?.lua;";

local my_name = arg[0];
if my_name:match("[/\\]") then
	package.path = package.path..";"..my_name:gsub("[^/\\]+$", "../?.lua");
	package.cpath = package.cpath..";"..my_name:gsub("[^/\\]+$", "../?.so");
end


-- ugly workaround for getting datamanager to work outside of prosody :(
prosody = { };
prosody.platform = "unknown";
if os.getenv("WINDIR") then
	prosody.platform = "windows";
elseif package.config:sub(1,1) == "/" then
	prosody.platform = "_posix";
end
package.loaded["util.logger"] = {init = function() return function() end; end}

local dm = require "util.datamanager";
dm.set_data_path("data");

local datetime = require "util.datetime";

local st = require "util.stanza";
local parse_xml = require "util.xml".parse;

function store_password(username, host, password)
	-- create or update account for username@host
	local ret, err = dm.store(username, host, "accounts", {password = password});
	print("["..(err or "success").."] stored account: "..username.."@"..host.." = "..password);
end

function store_vcard(username, host, stanza)
	-- create or update vCard for username@host
	local ret, err = dm.store(username, host, "vcard", st.preserialize(stanza));
	print("["..(err or "success").."] stored vCard: "..username.."@"..host);
end

function store_roster(username, host, roster_items)
	-- fetch current roster-table for username@host if he already has one
	local roster = dm.load(username, host, "roster") or {};
	-- merge imported roster-items with loaded roster
	for item_tag in roster_items:childtags() do
		-- jid for this roster-item
		local item_jid = item_tag.attr.jid
		-- validate item stanzas
		if (item_tag.name == "item") and (item_jid ~= "") then
			-- prepare roster item
			-- TODO: is the subscription attribute optional?
			local item = {subscription = item_tag.attr.subscription, groups = {}};
			-- optional: give roster item a real name
			if item_tag.attr.name then
				item.name = item_tag.attr.name;
			end
			-- optional: iterate over group stanzas inside item stanza
			for group_tag in item_tag:childtags() do
				local group_name = group_tag:get_text();
				if (group_tag.name == "group") and (group_name ~= "") then
					item.groups[group_name] = true;
				else
					print("[error] invalid group stanza: "..group_tag:pretty_print());
				end
			end
			-- store item in roster
			roster[item_jid] = item;
			print("[success] roster entry: " ..username.."@"..host.." - "..item_jid);
		else
			print("[error] invalid roster stanza: " ..item_tag:pretty_print());
		end

	end
	-- store merged roster-table
	local ret, err = dm.store(username, host, "roster", roster);
	print("["..(err or "success").."] stored roster: " ..username.."@"..host);
end

function store_subscription_request(username, host, presence_stanza)
	local from_bare = presence_stanza.attr.from;

	-- fetch current roster-table for username@host if he already has one
	local roster = dm.load(username, host, "roster") or {};

	local item = roster[from_bare];
	if item and (item.subscription == "from" or item.subscription == "both") then
		return; -- already subscribed, do nothing
	end

	-- add to table of pending subscriptions
	if not roster.pending then roster.pending = {}; end
	roster.pending[from_bare] = true;

	-- store updated roster-table
	local ret, err = dm.store(username, host, "roster", roster);
	print("["..(err or "success").."] stored subscription request: " ..username.."@"..host.." - "..from_bare);
end

local os_date = os.date;
local os_time = os.time;
local os_difftime = os.difftime;
function datetime_parse(s)
	if s then
		local year, month, day, hour, min, sec, tzd;
		year, month, day, hour, min, sec, tzd = s:match("^(%d%d%d%d)%-?(%d%d)%-?(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*([Z+%-]?.*)$");
		if year then
			local time_offset = os_difftime(os_time(os_date("*t")), os_time(os_date("!*t"))); -- to deal with local timezone
			local tzd_offset = 0;
			if tzd ~= "" and tzd ~= "Z" then
				local sign, h, m = tzd:match("([+%-])(%d%d):?(%d*)");
				if not sign then return; end
				if #m ~= 2 then m = "0"; end
				h, m = tonumber(h), tonumber(m);
				tzd_offset = h * 60 * 60 + m * 60;
				if sign == "-" then tzd_offset = -tzd_offset; end
			end
			sec = (sec + time_offset) - tzd_offset;
			return os_time({year=year, month=month, day=day, hour=hour, min=min, sec=sec, isdst=false});
		end
	end
end

function store_offline_messages(username, host, stanza)
	-- TODO: maybe use list_load(), append and list_store() instead
	--       of constantly reopening the file with list_append()?
	--for ch in offline_messages:childtags() do
		--print("message :"..ch:pretty_print());
		stanza.attr.node = nil;

		local stamp = stanza:get_child("x", "jabber:x:delay");
		if not stamp or not stamp.attr.stamp then print(2) return; end

		for i=1,#stanza do if stanza[i] == stamp then table.remove(stanza, i); break; end end
		for i=1,#stanza.tags do if stanza.tags[i] == stamp then table.remove(stanza.tags, i); break; end end

		local parsed_stamp = datetime_parse(stamp.attr.stamp);
		if not parsed_stamp then print(1, stamp.attr.stamp) return; end

		stanza.attr.stamp, stanza.attr.stamp_legacy = datetime.datetime(parsed_stamp), datetime.legacy(parsed_stamp);
		local ret, err = dm.list_append(username, host, "offline", st.preserialize(stanza));
		print("["..(err or "success").."] stored offline message: " ..username.."@"..host.." - "..stanza.attr.from);
	--end
end

-- load data
local arg = ...;
local help = "/? -? ? /h -h /help -help --help";
if not arg or help:find(arg, 1, true) then
	print([[XEP-227 importer for Prosody

  Usage: jabberd14sql2prosody.lua filename.sql
]]);
	os.exit(1);
end
local f = io.open(arg);
local s = f:read("*a");
f:close();

local table_count = 0;
local insert_count = 0;
local row_count = 0;
-- parse
parse_sql(s, {
	create = function(table_name, columns)
		--[[print(table_name);]]
		table_count = table_count + 1;
	end;
	insert = function(table_name, value_lists)
		--[[print(table_name, #value_lists);]]
		insert_count = insert_count + 1;
		row_count = row_count + #value_lists;

		for _,value_list in ipairs(value_lists) do
			if table_name == "users" then
				local user, realm, password = unpack(value_list);
				store_password(user, realm, password);
			elseif table_name == "roster" then
				local user, realm, xml = unpack(value_list);
				local stanza,err = parse_xml(xml);
				if stanza then
					store_roster(user, realm, stanza);
				else
					print("[error] roster: XML parsing failed for "..user.."@"..realm..": "..err);
				end
			elseif table_name == "vcard" then
				local user, realm, name, email, nickname, birthday, photo, xml = unpack(value_list);
				if xml then
					local stanza,err = parse_xml(xml);
					if stanza then
						store_vcard(user, realm, stanza);
					else
						print("[error] vcard: XML parsing failed for "..user.."@"..realm..": "..err);
					end
				else
					--print("[warn] vcard: NULL vCard for "..user.."@"..realm..": "..err);
				end
			elseif table_name == "storedsubscriptionrequests" then
				local user, realm, fromjid, xml = unpack(value_list);
				local stanza,err = parse_xml(xml);
				if stanza then
					store_subscription_request(user, realm, stanza);
				else
					print("[error] storedsubscriptionrequests: XML parsing failed for "..user.."@"..realm..": "..err);
				end
			elseif table_name == "messages" then
				--local user, realm, node, correspondent, type, storetime, delivertime, subject, body, xml = unpack(value_list);
				local user, realm, type, xml = value_list[1], value_list[2], value_list[5], value_list[10];
				if type == "offline" and xml ~= "" then
					local stanza,err = parse_xml(xml);
					if stanza then
						store_offline_messages(user, realm, stanza);
					else
						print("[error] offline messages: XML parsing failed for "..user.."@"..realm..": "..err);
						print(unpack(value_list));
					end
				end
			end
		end
	end;
});

print("table_count", table_count);
print("insert_count", insert_count);
print("row_count", row_count);

