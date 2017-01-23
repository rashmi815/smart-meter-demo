/*=================================================================================================
 *         APPLYING K-MEANS CLUSTERING
 *
 * - Cluster periodogram feature vectors using K-means algorithm in MADlib using k=...
 *     - Find the centroids of the clusters, cluster assignments for the periodograms, and the
 *      distances between each point and centroid for each cluster
 *    - Calculate silhouette coefficients for every data point(pgram) in each cluster level.
 *     - Calculate the average silhouette coefficient for each cluster level.
 * - Re-cluster ...
 *
 *
 *=================================================================================================
 */

-- Function that loops through to run k-means clustering for different values of k
CREATE OR REPLACE FUNCTION mgdemo.run_kmeans(
  input_table_with_schema VARCHAR,
  output_kmeans_table_with_schema VARCHAR,
  k_array INT[]
) RETURNS VOID AS
$$
  DECLARE
      sql TEXT;
      numk INT;
      num_features INT;
  BEGIN
      sql := 'DROP TABLE IF EXISTS ' || output_kmeans_table_with_schema || ';';
      EXECUTE sql;

      sql := 'CREATE TABLE ' || output_kmeans_table_with_schema
                || ' (k INT, centroids DOUBLE PRECISION[][], objective_fn DOUBLE PRECISION,'
                || ' frac_reassigned DOUBLE PRECISION, num_iterations INTEGER)'
                || ' DISTRIBUTED RANDOMLY;';
      EXECUTE sql;

      numk := array_upper(k_array,1);
      sql := 'SELECT array_upper(pgram,1) FROM ' || input_table_with_schema;
      EXECUTE sql INTO num_features;

      FOR i IN 1..numk LOOP
          RAISE INFO '===== i = % ==== k = % ===== START =====', i, k_array[i];
          sql := 'INSERT INTO ' || output_kmeans_table_with_schema
                  || ' SELECT'
                  || ' ' || k_array[i] || ','
                  || ' *'
                  || ' FROM madlib.kmeanspp('
                  || ' '' ' ||  input_table_with_schema || ''','
                  || ' ''pgram'','
                  || ' ' || k_array[i] || ','
                  || ' ''madlib.dist_norm2'','
                  || ' ''madlib.avg'','
                  || ' 100, 0.001);'
                  ;
          RAISE INFO '===== query =====';
          RAISE INFO '%', sql;
          EXECUTE sql;
          RAISE INFO '===== i = % ==== k = % ===== END =====', i, k_array[i];
      END LOOP;
  END;
$$
LANGUAGE 'plpgsql';
--

-- Run the function for 3 to 20 clusters
SELECT mgdemo.run_kmeans('mgdemo.mgdata_pgram_array_tbl','mgdemo.mgdata_kmeans_output_tbl',array_agg(km order by km))
FROM (SELECT generate_series(3,25,1) as km) t1;


/*
 * TABLE of centroids periodograms unnest from k-means output unnested. This TABLE is
 * used unnest the two dimensional centroids array from k-means output.
 */
CREATE TABLE mgdemo.mgdata_km_centroids_unnest_full_tbl AS
  SELECT
    k,
    ((row_number() over(partition by k))+(array_len-1))/array_len AS array_id,
    index_id,
    centroid_points
  FROM
  (
    SELECT
      k,
      array_len,
      generate_series(1,array_len,1) as index_id,
      unnest(centroids) AS centroid_points
    FROM (
      SELECT k, centroids, array_upper(centroids,2) AS array_len
      FROM mgdemo.mgdata_kmeans_output_tbl
    ) t1
  ) t2
DISTRIBUTED BY (k,array_id,index_id);


-- TABLE of centroids AND respective cid's.
CREATE TABLE mgdemo.mgdata_km_centroids_unnest_onelevel_cluster_id_tbl AS
  SELECT
    k,
    centroid_array,
    (madlib.closest_column(centroids_multidim_array, centroid_array)).column_id AS cluster_id
  FROM (
    SELECT
      t1.k,
      centroid_array,
      centroids as centroids_multidim_array
    FROM (
      SELECT
        k,
        array_agg(centroid_points ORDER BY index_id) AS centroid_array
      FROM
        mgdemo.mgdata_km_centroids_unnest_full_tbl
      GROUP BY
        k, array_id
    ) t1,
    mgdemo.mgdata_kmeans_output_tbl t2
    WHERE t1.k = t2.k
  ) t2
DISTRIBUTED RANDOMLY;


-- Assign cluster IDs to all data points
CREATE TABLE mgdemo.mgdata_pgram_array_cluster_id_tbl AS
  SELECT
    k,
    bgid,
    pgram,
    (madlib.closest_column(centroids_multidim_array, pgram)).column_id AS cluster_id
  FROM
    mgdemo.mgdata_pgram_array_tbl,
    (SELECT k, centroids AS centroids_multidim_array FROM mgdemo.mgdata_kmeans_output_tbl) t1
DISTRIBUTED BY (k,cluster_id,bgid);
