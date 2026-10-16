import unittest
from speech_metrics import alignment, transcript_metrics, residual_metrics, words, lufs, quiet_tail_metrics

class SpeechMetricsTests(unittest.TestCase):
    def test_wer_counts_insertions_deletions_and_substitutions(self):
        self.assertEqual(alignment(['a', 'b', 'c'], ['a', 'x', 'c', 'd']),
                         [('match', 0, 0), ('substitution', 1, 1), ('match', 2, 2), ('insertion', None, 3)])
        self.assertEqual(alignment(['a', 'b'], ['a'])[-1], ('deletion', 1, None))

    def test_normalization_keeps_fillers_numbers_and_german_umlauts(self):
        self.assertEqual(words('Äh, Clara! UM twenty-three 23.'), ['äh', 'clara', 'um', 'twenty', 'three', '23'])

    def test_timing_scores_only_matched_sentence_boundaries(self):
        truth = dict(reference_text='hello um Clara', sentences=[dict(text='hello um Clara', start_ns=1000000000, end_ns=2000000000)])
        transcript = dict(words=[dict(text='Hello', src_start_ns=1100000000, src_end_ns=1200000000),
                                 dict(text='Clara', src_start_ns=1700000000, src_end_ns=1800000000)])
        result = transcript_metrics(truth, transcript)
        self.assertAlmostEqual(result['wer'], 1/3)
        self.assertEqual(result['scored_sentence_boundaries'], 2)
        self.assertEqual(result['sentence_boundary_median_ms'], 150)
        self.assertEqual(result['sentence_boundary_max_ms'], 200)

    def test_german_preposition_is_not_ground_truth_filler(self):
        truth = dict(reference_text='Äh es beginnt um zehn', sentences=[dict(text='Äh es beginnt um zehn', start_ns=0, end_ns=100)])
        transcript = dict(words=[dict(text=text, src_start_ns=i*10, src_end_ns=i*10+9) for i, text in enumerate(['Äh', 'es', 'beginnt', 'um', 'zehn'])])
        result = transcript_metrics(truth, transcript)
        self.assertEqual(result['expected_fillers'], 1)
        self.assertEqual(result['recognized_fillers'], 2)
        self.assertEqual(result['correctly_aligned_fillers'], 1)
        self.assertEqual(result['unlabelled_filler_candidates'], 1)

    def test_quiet_tail_reports_noise_change_only_when_reference_is_silent(self):
        clean, noisy, output = [0.]*48000, [.1]*48000, [.05]*48000
        result = quiet_tail_metrics(clean, noisy, output)
        self.assertAlmostEqual(result['reduction_db'], 6.020599913, places=6)
        clean[-1] = .1
        self.assertIsNone(quiet_tail_metrics(clean, noisy, output))

    def test_ffmpeg_loudness_accepts_progress_lines_after_json(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        output = 'ffmpeg log\n{"input_i": "-16.08", "input_tp": "-1.00"}\n[out#0/null] video:0KiB audio:123KiB\n'
        with patch('speech_metrics.subprocess.run', return_value=SimpleNamespace(stderr=output)):
            self.assertEqual(lufs('unused.wav'), -16.08)
        with patch('speech_metrics.subprocess.run', return_value=SimpleNamespace(stderr='{"input_i":"-inf"}\n')):
            self.assertIsNone(lufs('unused.wav'))

    def test_residual_metric_reports_distortion_and_rejects_length_changes(self):
        result = residual_metrics([1., -1., 1., -1.], [1.1, -.9, 1.1, -.9])
        self.assertAlmostEqual(result['reference_gain'], 1.)
        self.assertAlmostEqual(result['si_sdr_db'], 20.)
        self.assertEqual(result['clipped_samples'], 2)
        with self.assertRaises(ValueError): residual_metrics([.1], [.1, .2])
        with self.assertRaises(ValueError): residual_metrics([0.], [.1])

if __name__ == '__main__': unittest.main()
