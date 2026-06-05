plugins {
  id("org.jetbrains.kotlin.jvm")
  id("org.jetbrains.kotlin.plugin.serialization")
}

dependencies {
  implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
  implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
  implementation("org.bouncycastle:bcprov-jdk18on:1.78.1")
  testImplementation("junit:junit:4.13.2")
}

kotlin {
  jvmToolchain(17)
}
