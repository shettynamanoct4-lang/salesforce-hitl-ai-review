/**
 * @description Org Platform Cache wrapper. A warm page reload makes zero callouts to the AI service.
 *              Falls back gracefully when no cache partition is configured.
 * @author      Naman G Shetty
 */
public with sharing class RecommendationCache {

    private static final String KEY = 'local.AiReview.pending';
    private static final Integer TTL_SECONDS = 6 * 60 * 60;

    public static List<RecommendationClient.Recommendation> get() {
        try {
            return (List<RecommendationClient.Recommendation>) Cache.Org.get(KEY);
        } catch (Exception e) {
            return null;
        }
    }

    public static void put(List<RecommendationClient.Recommendation> recs) {
        try {
            Cache.Org.put(KEY, recs, TTL_SECONDS);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Platform Cache unavailable: ' + e.getMessage());
        }
    }

    public static void clear() {
        try {
            Cache.Org.remove(KEY);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Platform Cache unavailable: ' + e.getMessage());
        }
    }
}
