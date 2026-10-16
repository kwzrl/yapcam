import unittest
from speech_metrics import alignment, transcript_metrics, residual_metrics, words

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

    def test_residual_metric_reports_distortion_and_rejects_length_changes(self):
        result = residual_metrics([1., -1., 1., -1.], [1.1, -.9, 1.1, -.9])
        self.assertAlmostEqual(result['reference_gain'], 1.)
        self.assertAlmostEqual(result['si_sdr_db'], 20.)
        self.assertEqual(result['clipped_samples'], 2)
        with self.assertRaises(ValueError): residual_metrics([.1], [.1, .2])
        with self.assertRaises(ValueError): residual_metrics([0.], [.1])

if __name__ == '__main__': unittest.main()
