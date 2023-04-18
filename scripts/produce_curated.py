import sys
from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from pyspark.context import SparkContext
from pyspark.sql.functions import udf
from pyspark.sql.types import StringType
from awsglue.utils import getResolvedOptions

glueContext = GlueContext(SparkContext.getOrCreate())

args = getResolvedOptions(sys.argv, [
  'JOB_NAME',
  'input-path',
  'output-path',
  'error-path'
])

input_path = args['input_path']
output_path = args['output_path']
error_path = args['error_path']

print(f"input {input_path}")
print(f"output {output_path}")
print(f"error {error_path}")

spark = glueContext.spark_session

df3 = spark.read.options(header='True', inferSchema='True') \
  .csv(input_path)

df3.show()

df3.write.parquet(output_path, mode="overwrite")
