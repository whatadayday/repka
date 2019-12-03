<?php
namespace App\Repositories;
use App\Models\News,
    App\Models\Tag,
    App\Models\Comment;
class NewsfeedRepository extends BaseRepository
{
    /*
     * The Tag instance.
     *
     * @var App\Models\Tag
     */
    protected $tag;
    /*
     * The Comment instance.
     *
     * @var App\Models\Comment
     */
    protected $comment;
    /* 
     * Create a new NewsfeedRepository instance.
     *
     * @param  App\Models\News $news
     * @param  App\Models\Tag $tag
     * @param  App\Models\Comment $comment
     * @return void
     */
    
    public function __construct(
    News $news, Tag $tag, Comment $comment) 
    {
        $this->model = $news;
        $this->tag = $tag;
        $this->comment = $comment;
    }
    /*
     * Create or update a news.
     *
     * @param  App\Models\News $news
     * @param  array  $inputs
     * @param  bool   $user_id
     * @return App\Models\News
     */

    private function saveNews( $news, $inputs, $user_id = null)
    {
        $news->title = $inputs['title'];
        $news->summary = $inputs['summary'];
        $news->content = $inputs['content'];
        $news->slug = $inputs['slug'];
        $news->active = isset($inputs['active']);
        if ($user_id) {
            $news->user_id = $user_id;
        }
        $news->save();
        return $news;
    }
    /**
     * Create a query for News.
     *
     * @return Illuminate\Database\Eloquent\Builder
     */
    private function queryActiveWithUserOrderByDate()
    {
        return $this->model
            ->select( 'id', 'created_at', 'updated_at', 'title', 'slug', 'user_id', 'summary')
                        ->whereActive(true)
                        ->with('user')
                        ->latest();
    }
    /**
     * Get news collection.
     *
     * @param  int  $n
     * @return Illuminate\Support\Collection
     */
    public function indexFront($n)
    {
        $query = $this->queryActiveWithUserOrderByDate();
        return $query->paginate($n);
    }
    /**
     * Get news collection.
     *
     * @param  int  $n
     * @param  int  $id
     * @return Illuminate\Support\Collection
     */
    public function indexTag($n, $id)
    {
        $query = $this->queryActiveWithUserOrderByDate();
        return $query->whereHas('tags', function($q) use($id) {
                            $q->where('tags.id', $id);
                        })
                        ->paginate($n);
    }
    /**
     * Get search collection.
     *
     * @param  int  $n
     * @param  string  $search
     * @return Illuminate\Support\Collection
     */
    public function search( $n, $search)
    {
        $query = $this->queryActiveWithUserOrderByDate();
        return $query->where(function($q) use ($search) {
                    $q->where('summary', 'like', "%$search%")
                            ->orWhere('content', 'like', "%$search%")
                            ->orWhere('title', 'like', "%$search%");
                })->paginate($n);
    }
    /**
     * Get news collection.
     *
     * @param  int     $n
     * @param  int     $user_id
     * @param  string  $orderby
     * @param  string  $direction
     * @return Illuminate\Support\Collection
     */
    public function index( $n, $user_id = null, $orderby = 'created_at', $direction = 'desc')
    {
        $query = $this->model
                ->select('newsfeed.id', 'newsfeed.created_at', 'title', 'newsfeed.seen', 'active', 'user_id', 'slug', 'username')
                ->join('users', 'users.id', '=', 'newsfeed.user_id')
                ->orderBy($orderby, $direction);
        if ($user_id) {
            $query->where('user_id', $user_id);
        }
        return $query->paginate($n);
    }
    /**
     * Get news collection.
     *
     * @param  string  $slug
     * @return array
     */
    public function show( $slug)
    {
        $news = $this->model->with('user', 'tags')->whereSlug($slug)->firstOrFail();
        $comments = $this->comment
                ->whereNews_id($news->id)
                ->with('user')
                ->whereHas('user', function($q) {
                    $q->whereValid(true);
                })
                ->get();
        return compact('news', 'comments');
    }
    /**
     * Get news collection.
     *
     * @param  App\Models\News $news
     * @return array
     */
    public function edit( $news)
    {
        $tags = [];
        foreach ($news->tags as $tag) {
            array_push($tags, $tag->tag);
        }
        return compact('news', 'tags');
    }
    /**
     * Get news collection.
     *
     * @param  int  $id
     * @return array
     */
    public function GetByIdWithTags( $id)
    {
        return $this->model->with('tags')->findOrFail($id);
    }
    /**
     * Update a news.
     *
     * @param  array  $inputs
     * @param  App\Models\News $news
     * @return void
     */
    public function update( $inputs, $news)
    {
        $news = $this->saveNews($news, $inputs);
        // Tag gestion
        $tags_id = [];
        if (array_key_exists('tags', $inputs) && $inputs['tags'] != '') {
            $tags = explode(',', $inputs['tags']);
            foreach ($tags as $tag) {
                $tag_ref = $this->tag->whereTag($tag)->first();
                if (is_null($tag_ref)) {
                    $tag_ref = new $this->tag();
                    $tag_ref->tag = $tag;
                    $tag_ref->save();
                }
                array_push($tags_id, $tag_ref->id);
            }
        }
        $news->tags()->sync($tags_id);
    }
    /**
     * Update "seen" in news.
     *
     * @param  array  $inputs
     * @param  int    $id
     * @return void
     */
    public function updateSeen( $inputs, $id)
    {
        $news = $this->getById($id);
        $news->seen = $inputs['seen'] == 'true';
        $news->save();
    }
    /**
     * Update "active" in news.
     *
     * @param  array  $inputs
     * @param  int    $id
     * @return void
     */
    public function updateActive( $inputs, $id)
    {
        $news = $this->getById($id);
        $news->active = $inputs['active'] == 'true';
        $news->save();
    }
    /**
     * Create a news.
     *
     * @param  array  $inputs
     * @param  int    $user_id
     * @return void
     */
    public function store( $inputs, $user_id)
    {
        $news = $this->saveNews(new $this->model, $inputs, $user_id);
        // Tags gestion
        if (array_key_exists('tags', $inputs) && $inputs['tags'] != '') {
            $tags = explode(',', $inputs['tags']);
            foreach ($tags as $tag) {
                $tag_ref = $this->tag->whereTag($tag)->first();
                if (is_null($tag_ref)) {
                    $tag_ref = new $this->tag();
                    $tag_ref->tag = $tag;
                    $news->tags()->save($tag_ref);
                } else {
                    $news->tags()->attach($tag_ref->id);
                }
            }
        }
        // Maybe purge orphan tags...
    }
    /**
     * Destroy a news.
     *
     * @param  App\Models\News $news
     * @return void
     */
    public function destroy($news) {
        $news->tags()->detach();
        $news->delete();
    }
    /**
     * Get news slug.
     *
     * @param  int  $comment_id
     * @return string
     */
    public function getSlug($comment_id)
    {
        return $this->comment->findOrFail($comment_id)->news->slug;
    }
    /**
     * Get tag name by id.
     *
     * @param  int  $tag_id
     * @return string
     */
    public function getTagById($tag_id)
    {
        return $this->tag->findOrFail($tag_id)->tag;
    }
}