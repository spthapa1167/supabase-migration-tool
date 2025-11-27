import "https://deno.land/x/xhr@0.1.0/mod.ts";
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req)=>{
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    const { content, language = 'english', type = 'title' } = await req.json();
    if (!content || content.trim().length < 10) {
      throw new Error('Content too short for generation');
    }
    // Truncate content to avoid token limits (first 2000 characters)
    const truncatedContent = content.substring(0, 2000);
    if (type === 'description') {
      return await generateDescription(truncatedContent, language);
    } else {
      return await generateTitle(truncatedContent, language);
    }
  } catch (error) {
    console.error('Error in generate-title function:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error occurred';
    return new Response(JSON.stringify({
      error: errorMessage
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  }
});
async function generateTitle(content, language) {
  try {
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content: `CRITICAL LANGUAGE REQUIREMENT: ${getLanguageSpecificTitleInstructions(language)}
YOU MUST GENERATE THE TITLE ENTIRELY IN ${language.toUpperCase()}. DO NOT USE ENGLISH OR ANY OTHER LANGUAGE.

You are an expert podcast title creator who specializes in creating engaging, compelling titles that drive listener interest.

TITLE CHARACTERISTICS:
- Are 3-8 words long (optimal for discovery and sharing)
- Capture the core topic/theme clearly and concisely
- Create curiosity or emotional appeal without being clickbait
- Use power words when appropriate (Ultimate, Secret, Essential, Proven, etc.)
- Include numbers when relevant (5 Tips, 3 Strategies, etc.)
- Avoid generic words like "Discussion" or "Conversation"
- Are memorable and shareable
- Use culturally appropriate language and expressions

STYLE VARIATIONS (pick one randomly):
1. DIRECT & CLEAR: Straightforward titles that state the topic clearly
2. QUESTION FORMAT: Titles that pose intriguing questions to hook listeners
3. BENEFIT-FOCUSED: Emphasize what listeners will gain or learn
4. STORY-DRIVEN: Hint at narrative or journey aspects
5. EXPERT INSIGHT: Position as insider knowledge or expert perspective

CREATIVE APPROACHES:
- Try different angles: historical, practical, psychological, cultural
- Vary tone: professional, conversational, urgent, inspiring
- Experiment with formats: "How to...", "The Truth About...", "Inside..."
- Use unexpected word combinations for memorability

${getLanguageSpecificExamples(language)}

IMPORTANT: Generate a DIFFERENT style and angle each time. Be creative and vary your approach to ensure unique results every time.

Return ONLY the title, no quotes, explanations, or additional text.`
          },
          {
            role: 'user',
            content: `Create a compelling podcast title for this content (try a fresh, unique approach):\n\n${content}\n\nVariation seed: ${Math.random().toString(36).substring(7)}`
          }
        ],
        max_completion_tokens: 30
      })
    });
    if (!response.ok) {
      const error = await response.text();
      console.error('Lovable AI error:', error);
      throw new Error('Failed to generate title');
    }
    const data = await response.json();
    const title = data.choices[0].message.content.trim();
    // Clean up the title (remove quotes if present)
    const cleanTitle = title.replace(/^["']|["']$/g, '');
    return new Response(JSON.stringify({
      title: cleanTitle
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error('Error generating title:', error);
    const fallbackTitles = {
      english: 'Generated Podcast Episode',
      spanish: 'Episodio de Podcast Generado',
      french: 'Épisode de Podcast Généré',
      german: 'Generierte Podcast-Episode',
      chinese: '生成的播客剧集',
      hindi: 'जनरेट किया गया पॉडकास्ट एपिसोड',
      arabic: 'حلقة البودكاست المُنشأة',
      portuguese: 'Episódio de Podcast Gerado',
      russian: 'Сгенерированный Эпизод Подкаста',
      japanese: '生成されたポッドキャストエピソード',
      korean: '생성된 팟캐스트 에피소드'
    };
    return new Response(JSON.stringify({
      title: fallbackTitles[language] || fallbackTitles.english
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  }
}
async function generateDescription(content, language) {
  try {
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content: `CRITICAL LANGUAGE REQUIREMENT: ${getLanguageSpecificDescriptionInstructions(language)}
YOU MUST GENERATE THE DESCRIPTION ENTIRELY IN ${language.toUpperCase()}. DO NOT USE ENGLISH OR ANY OTHER LANGUAGE.

You are an expert podcast description writer. Create engaging, concise descriptions that capture the essence of podcast content.

CRITICAL RULES - ABSOLUTELY NO HOST/GUEST REFERENCES:
- NEVER mention host or guest names (e.g., "Emma", "David", any person names)
- NEVER use "Join...", "Meet...", "with [Name]", "hosted by", "featuring", "as they", "unveil", "they discuss"
- NEVER reference speakers, presenters, or any people
- Write as if describing the content itself, NOT a conversation about it
- Start directly with the topic/theme

DESCRIPTION STYLE:
- Keep it to 1-2 short sentences (100-150 characters max)
- Use active, compelling language
- Focus purely on what the content explores/reveals/uncovers
- Good examples:
  * "Kathmandu's hidden gems blend rich culture with urban evolution in Nepal's vibrant heart."
  * "Discover the science behind habit formation and lasting behavioral change."
  * "Uncover sustainable design principles reshaping modern architecture."

Generate a pure content description with ZERO references to people, hosts, or guests.`
          },
          {
            role: 'user',
            content: `Create a compelling description for this podcast content:

${content}

STRICT REQUIREMENTS:
- 1-2 sentences, 100-150 characters
- ABSOLUTELY NO names, hosts, guests, or people
- Focus ONLY on topic and themes
- Start with the subject matter directly
- Seed: ${Math.random().toString(36).substring(7)}`
          }
        ],
        max_tokens: 100,
        temperature: 0.8 // Increased for more variety
      })
    });
    if (!response.ok) {
      const error = await response.text();
      console.error('OpenAI API error:', error);
      throw new Error('Failed to generate description');
    }
    const data = await response.json();
    const description = data.choices[0].message.content.trim();
    // Ensure it's not too long
    const cleanDescription = description.length > 200 ? description.substring(0, 200) + '...' : description;
    return new Response(JSON.stringify({
      description: cleanDescription
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error('Error generating description:', error);
    const fallbackDescriptions = {
      english: 'An engaging podcast discussion covering key insights and perspectives on important topics.',
      spanish: 'Una discusión de podcast cautivadora que cubre ideas clave y perspectivas sobre temas importantes.',
      french: 'Une discussion de podcast captivante couvrant des idées clés et des perspectives sur des sujets importants.',
      german: 'Eine fesselnde Podcast-Diskussion über wichtige Einblicke und Perspektiven zu wichtigen Themen.',
      chinese: '一场引人入胜的播客讨论，涵盖重要主题的关键见解和观点。',
      hindi: 'एक आकर्षक पॉडकास्ट चर्चा जो महत्वपूर्ण विषयों पर प्रमुख अंतर्दृष्टि और दृष्टिकोण को कवर करती है।',
      arabic: 'مناقشة بودكاست جذابة تغطي رؤى ووجهات نظر رئيسية حول مواضيع مهمة.',
      portuguese: 'Uma discussão de podcast envolvente cobrindo insights e perspectivas importantes sobre tópicos relevantes.',
      russian: 'Увлекательная подкаст-дискуссия, охватывающая ключевые идеи и перспективы по важным темам.',
      japanese: '重要なトピックに関する主要な洞察と視点をカバーする魅力的なポッドキャスト討論。',
      korean: '중요한 주제에 대한 주요 통찰력과 관점을 다루는 매력적인 팟캐스트 토론.'
    };
    return new Response(JSON.stringify({
      description: fallbackDescriptions[language] || fallbackDescriptions.english
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  }
}
function getLanguageSpecificTitleInstructions(language) {
  const instructions = {
    english: 'Generate titles in clear, compelling English.',
    chinese: '用中文生成标题。绝对不要使用英语或其他语言。',
    hindi: 'हिंदी में शीर्षक बनाएं। अंग्रेजी या अन्य भाषा का उपयोग बिल्कुल न करें।',
    spanish: 'Genera títulos en español. No uses inglés ni otros idiomas.',
    french: 'Générez des titres en français. N\'utilisez pas l\'anglais ou d\'autres langues.',
    arabic: 'أنشئ عناوين باللغة العربية. لا تستخدم الإنجليزية أو أي لغات أخرى.',
    bengali: 'বাংলায় শিরোনাম তৈরি করুন। ইংরেজি বা অন্য ভাষা ব্যবহার করবেন না।',
    portuguese: 'Gere títulos em português. Não use inglês ou outros idiomas.',
    russian: 'Создавайте заголовки на русском языке. Не используйте английский или другие языки.',
    japanese: '日本語でタイトルを生成します。英語や他の言語は使用しないでください。',
    punjabi: 'ਪੰਜਾਬੀ ਵਿੱਚ ਸਿਰਲੇਖ ਬਣਾਓ। ਅੰਗਰੇਜ਼ੀ ਜਾਂ ਹੋਰ ਭਾਸ਼ਾ ਦੀ ਵਰਤੋਂ ਨਾ ਕਰੋ।',
    nepali: 'नेपालीमा शीर्षक सिर्जना गर्नुहोस्। अंग्रेजी वा अन्य भाषा प्रयोग नगर्नुहोस्।',
    german: 'Erstellen Sie Titel auf Deutsch. Verwenden Sie kein Englisch oder andere Sprachen.',
    italian: 'Genera titoli in italiano. Non usare inglese o altre lingue.',
    korean: '한국어로 제목을 생성합니다. 영어나 다른 언어를 사용하지 마세요.',
    dutch: 'Genereer titels in het Nederlands. Gebruik geen Engels of andere talen.',
    turkish: 'Türkçe başlık oluşturun. İngilizce veya diğer dilleri kullanmayın.',
    vietnamese: 'Tạo tiêu đề bằng tiếng Việt. Không sử dụng tiếng Anh hoặc ngôn ngữ khác.'
  };
  return instructions[language] || instructions.english;
}
function getLanguageSpecificExamples(language) {
  const examples = {
    english: `EXAMPLES OF GOOD TITLES:
- "The Science of Better Sleep"
- "5 Startup Lessons from Failures"
- "Building Wealth in Your 30s"
- "AI's Impact on Creative Work"
- "Mastering Remote Team Culture"`,
    chinese: `好标题示例：
- "更好睡眠的科学"
- "创业失败的5个教训"
- "30岁后的财富建设"
- "AI对创意工作的影响"
- "远程团队文化管理"`,
    spanish: `EJEMPLOS DE BUENOS TÍTULOS:
- "La Ciencia del Mejor Sueño"
- "5 Lecciones de Startups Fallidas"
- "Construir Riqueza en los 30"
- "El Impacto de la IA en el Trabajo Creativo"
- "Dominando la Cultura de Equipos Remotos"`,
    french: `EXEMPLES DE BONS TITRES:
- "La Science du Meilleur Sommeil"
- "5 Leçons des Startups Échouées"
- "Construire la Richesse dans la Trentaine"
- "L'Impact de l'IA sur le Travail Créatif"
- "Maîtriser la Culture d'Équipe à Distance"`,
    hindi: `अच्छे शीर्षकों के उदाहरण:
- "बेहतर नींद का विज्ञान"
- "असफल स्टार्टअप्स से 5 सबक"
- "30 की उम्र में धन निर्माण"
- "रचनात्मक कार्य पर AI का प्रभाव"
- "रिमोट टीम संस्कृति में महारत"`
  };
  return examples[language] || examples.english;
}
function getLanguageSpecificDescriptionInstructions(language) {
  const instructions = {
    english: 'Write in engaging, natural English.',
    chinese: '用自然的中文写作。不要使用英语。',
    hindi: 'प्राकृतिक हिंदी में लिखें। अंग्रेजी का उपयोग न करें।',
    spanish: 'Escribe en español natural. No uses inglés.',
    french: 'Écrivez en français naturel. N\'utilisez pas l\'anglais.',
    arabic: 'اكتب باللغة العربية الطبيعية. لا تستخدم الإنجليزية.',
    bengali: 'প্রাকৃতিক বাংলায় লিখুন। ইংরেজি ব্যবহার করবেন না।',
    portuguese: 'Escreva em português natural. Não use inglês.',
    russian: 'Пишите на естественном русском языке. Не используйте английский.',
    japanese: '自然な日本語で書いてください。英語は使用しないでください。',
    punjabi: 'ਕੁਦਰਤੀ ਪੰਜਾਬੀ ਵਿੱਚ ਲਿਖੋ। ਅੰਗਰੇਜ਼ੀ ਨਾ ਵਰਤੋ।',
    nepali: 'प्राकृतिक नेपालीमा लेख्नुहोस्। अंग्रेजी प्रयोग नगर्नुहोस्।',
    german: 'Schreiben Sie in natürlichem Deutsch. Verwenden Sie kein Englisch.',
    italian: 'Scrivi in italiano naturale. Non usare inglese.',
    korean: '자연스러운 한국어로 작성하세요. 영어를 사용하지 마세요.',
    dutch: 'Schrijf in natuurlijk Nederlands. Gebruik geen Engels.',
    turkish: 'Doğal Türkçe ile yazın. İngilizce kullanmayın.',
    vietnamese: 'Viết bằng tiếng Việt tự nhiên. Không sử dụng tiếng Anh.'
  };
  return instructions[language] || instructions.english;
}
