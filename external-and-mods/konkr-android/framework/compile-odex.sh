#!/system/bin/sh
# compile-odex.sh — run inside a Lepton container with the patched jar at
# /data/local/tmp/services.jar. Rebuilds everything that embeds the
# services.jar checksum: services.{odex,vdex,art}, ethernet-service.{odex,vdex}
# and the system_server apex jars the stock image prebakes into /data/dalvik-cache.
# Output: /data/local/tmp/out/ laid out like the konkr overlay.
set -e
export ANDROID_ROOT=/system ANDROID_ART_ROOT=/apex/com.android.art ANDROID_I18N_ROOT=/apex/com.android.i18n \
       ANDROID_TZDATA_ROOT=/apex/com.android.tzdata ANDROID_DATA=/data
T=/data/local/tmp
BCP=$(grep DEX2OATBOOTCLASSPATH /init.environ.rc | awk '{print $3}')
d2o() {
  filter=$1; shift
  /apex/com.android.art/bin/dex2oat64 --instruction-set=arm64 --instruction-set-variant=cortex-a76 \
    --instruction-set-features=default --compiler-filter=$filter \
    --boot-image=/apex/com.android.art/javalib/boot.art:/system/framework/boot-framework.art \
    --runtime-arg -Xbootclasspath:$BCP --runtime-arg -Xbootclasspath-locations:$BCP \
    --runtime-arg -Xms64m --runtime-arg -Xmx512m --generate-mini-debug-info -j4 "$@"
}
B=/system/framework/org.lineageos.platform.jar:/system/framework/com.android.location.provider.jar
E=/system/framework/ethernet-service.jar
SP=/apex/com.android.permission/javalib/service-permission.jar
IK=/apex/com.android.ipsec/javalib/android.net.ipsec.ike.jar
O=$T/out/system/framework/oat/arm64
DC=$T/out/data/dalvik-cache/arm64
rm -rf $T/out; mkdir -p $O $DC

d2o speed --compilation-reason=prebuilt --dex-file=$T/services.jar --dex-location=/system/framework/services.jar \
  --oat-file=$O/services.odex --output-vdex=$O/services.vdex --app-image-file=$O/services.art --image-format=lz4 \
  --oat-location=/system/framework/oat/arm64/services.odex --class-loader-context="PCL[$B]"
d2o speed --compilation-reason=prebuilt --dex-file=$E --dex-location=$E \
  --oat-file=$O/ethernet-service.odex --output-vdex=$O/ethernet-service.vdex \
  --oat-location=/system/framework/oat/arm64/ethernet-service.odex \
  --class-loader-context="PCL[$B:$T/services.jar]" --stored-class-loader-context="PCL[$B:/system/framework/services.jar]"
d2o verify --dex-file=$SP --dex-location=$SP \
  --oat-file=$DC/apex@com.android.permission@javalib@service-permission.jar@classes.dex \
  --output-vdex=$DC/apex@com.android.permission@javalib@service-permission.jar@classes.vdex \
  --oat-location=/data/dalvik-cache/arm64/apex@com.android.permission@javalib@service-permission.jar@classes.dex \
  --class-loader-context="PCL[$B:$T/services.jar:$E]" --stored-class-loader-context="PCL[$B:/system/framework/services.jar:$E]"
d2o verify --dex-file=$IK --dex-location=$IK \
  --oat-file=$DC/apex@com.android.ipsec@javalib@android.net.ipsec.ike.jar@classes.dex \
  --output-vdex=$DC/apex@com.android.ipsec@javalib@android.net.ipsec.ike.jar@classes.vdex \
  --oat-location=/data/dalvik-cache/arm64/apex@com.android.ipsec@javalib@android.net.ipsec.ike.jar@classes.dex \
  --class-loader-context="PCL[$B:$T/services.jar:$E:$SP]" --stored-class-loader-context="PCL[$B:/system/framework/services.jar:$E:$SP]"
ls -la $O $DC
