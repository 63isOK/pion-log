# pion/randutil

这是一个基础工具库,创建一些数学上的随机数和密码学的随机数

准备分4部分来学习这个库.

## 数学随机数

对外暴露的是一个接口类型和一个构造数学随机数的函数.

		type MathRandomGenerator interface {
			Intn(n int) int
			Uint32() uint32
			Uint64() uint64
			GenerateString(n int, runes string) string
		}

一个实现接口的类型

		type mathRandomGenerator struct {
			r  *mrand.Rand
			mu sync.Mutex
		}

		func (g *mathRandomGenerator) Intn(n int) int {
			g.mu.Lock()
			v := g.r.Intn(n)
			g.mu.Unlock()
			return v
		}

		func (g *mathRandomGenerator) Uint32() uint32 {
			g.mu.Lock()
			v := g.r.Uint32()
			g.mu.Unlock()
			return v
		}

		func (g *mathRandomGenerator) Uint64() uint64 {
			g.mu.Lock()
			v := g.r.Uint64()
			g.mu.Unlock()
			return v
		}

		func (g *mathRandomGenerator) GenerateString(n int, runes string) string {
			letters := []rune(runes)
			b := make([]rune, n)
			for i := range b {
				b[i] = letters[g.Intn(len(letters))]
			}
			return string(b)
		}
		
从结构上看,并不复杂.相对于标准库来说,少了一个默认处理:

- 构造一个默认的mathRandomGenerator对象,这个对象是不暴露的
- 将接口的4个方法,通过4个函数对外暴露

文档说明:

- 这里的随机数,可用于非加密的唯一id,或随机端口号

这儿的随机都是利用math/rand包完成的,先看下math/rand包.

### math/rand

rand包是伪随机数生成器.

生成器需要有个源,用Seed函数可以生成随机数的源.
源一定,生成的随机数序列也是一定的.

源source和随机数种子seed不是一个概念,分析源码可知.

		func NewSource(seed int64) Source
		func New(src Source) *
		func (r *Rand) Intn(n int) int
		func (r *Rand) Uint32() uint32
    func (r *Rand) Uint64() uint64

从上面的部分接口可以看出,从随机数种子生成源,从源生成随机数生成器,
最后通过生成器生成各种数值.

### mathRandomGenerator分析

mathRandomGenerator结构体包含一个生成器和一个互斥量.
她的4个方法都很好理解.

看下构造函数.

		func NewMathRandomGenerator() MathRandomGenerator {
			seed, err := CryptoUint64()
			if err != nil {
				seed = uint64(time.Now().UnixNano())
			}

			return &mathRandomGenerator{r: mrand.New(mrand.NewSource(int64(seed)))}
		}

用CryptoUint64生成一个种子,如果不成功,还是选用时间为种子.

整体来说还是蛮简单的,不复杂.

## 数学随机数的测试

测试例子做了一个撞库测试,
MathRandom.gen是从字母序列中随机选取10个字母组成一个字符串.
每次生成100个字符串,判断相互之间是否重复,整个过程重复100次.

		const runesAlpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

		func TestRandomGeneratorCollision(t *testing.T) {
			g := NewMathRandomGenerator()

			testCases := map[string]struct {
				gen func(t *testing.T) string
			}{
				"MathRandom": {
					gen: func(t *testing.T) string {
						return g.GenerateString(10, runesAlpha)
					},
				},
				"CryptoRandom": {
					gen: func(t *testing.T) string {
						s, err := GenerateCryptoRandomString(10, runesAlpha)
						if err != nil {
							t.Fatal(err)
						}
						return s
					},
				},
			}

			const N = 100
			const iteration = 100

			for name, testCase := range testCases {
				testCase := testCase
				t.Run(name, func(t *testing.T) {
					for iter := 0; iter < iteration; iter++ {
						var wg sync.WaitGroup
						var mu sync.Mutex

						rands := make([]string, 0, N)

						for i := 0; i < N; i++ {
							wg.Add(1)
							go func() {
								r := testCase.gen(t)
								mu.Lock()
								rands = append(rands, r)
								mu.Unlock()
								wg.Done()
							}()
						}
						wg.Wait()

						if len(rands) != N {
							t.Fatal("Failed to generate randoms")
						}

						for i := 0; i < N; i++ {
							for j := i + 1; j < N; j++ {
								if rands[i] == rands[j] {
									t.Fatalf("generateRandString caused collision: %s == %s", rands[i], rands[j])
								}
							}
						}
					}
				})
			}
		}

整个撞库测试并不复杂,但是可以拆的细一点,函数太长了.

## 密码学随机数

## 密码学随机数的测试